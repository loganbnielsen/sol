type cmd =
  { argv : string list
  ; cwd : string option
  ; env : (string * string) list option
  ; inherit_env : bool
  ; timeout_s : float option
  ; redact : string list
  }

type failure =
  { exit_code : int
  ; stdout : string
  ; stderr : string
  }

type output =
  { stdout : string
  ; stderr : string
  }

type error =
  | Spawn_failed of string
  | Non_zero of failure
  | Timeout of float

let cmd ?cwd ?env ?(inherit_env = true) ?timeout_s ?(redact = []) argv =
  { argv; cwd; env; inherit_env; timeout_s; redact }
;;

let completed ~exit_code ~stdout ~stderr =
  if exit_code = 0
  then Ok { stdout; stderr }
  else Error (Non_zero { exit_code; stdout; stderr })
;;

let error_to_string = function
  | Spawn_failed msg -> Printf.sprintf "spawn failed: %s" msg
  | Non_zero { exit_code; stderr; stdout } ->
    (match String.trim stderr, String.trim stdout with
     | "", "" -> Printf.sprintf "exited with code %d" exit_code
     | "", said | said, _ -> Printf.sprintf "exited with code %d: %s" exit_code said)
  | Timeout s -> Printf.sprintf "timed out after %.1fs" s
;;

let apply_redactions redact s =
  List.fold_left
    (fun acc secret ->
       if secret = ""
       then acc
       else (
         let buf = Buffer.create (String.length acc) in
         let slen = String.length secret
         and alen = String.length acc in
         let rec loop i =
           if i > alen - slen
           then Buffer.add_substring buf acc i (alen - i)
           else if String.sub acc i slen = secret
           then (
             Buffer.add_string buf "***";
             loop (i + slen))
           else (
             Buffer.add_char buf acc.[i];
             loop (i + 1))
         in
         loop 0;
         Buffer.contents buf))
    s
    redact
;;

let echo_cmd argv redact =
  let display = String.concat " " (List.map Filename.quote argv) in
  Sol_cli_report.app "  $ %s" (apply_redactions redact display)
;;

let merge_env extras =
  let current = Unix.environment () in
  let extra_keys = List.map fst extras in
  let filtered =
    Array.to_list current
    |> List.filter (fun entry ->
      let key =
        match String.index_opt entry '=' with
        | Some i -> String.sub entry 0 i
        | None -> entry
      in
      not (List.mem key extra_keys))
  in
  Array.of_list (filtered @ List.map (fun (k, v) -> k ^ "=" ^ v) extras)
;;

let environment c =
  match c.env with
  | None -> if c.inherit_env then Unix.environment () else [||]
  | Some extras when c.inherit_env -> merge_env extras
  | Some extras -> Array.of_list (List.map (fun (key, value) -> key ^ "=" ^ value) extras)
;;

let close_noerr fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let read_available fd buf =
  let bytes = Bytes.create 4096 in
  match Unix.read fd bytes 0 (Bytes.length bytes) with
  | 0 -> `Closed
  | n ->
    Buffer.add_subbytes buf bytes 0 n;
    `Open
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
    `Open
;;

let rec select_ready ?deadline reads =
  match deadline with
  | Some d when d -. Unix.gettimeofday () <= 0.0 -> `Expired
  | _ ->
    let timeout =
      match deadline with
      | None -> -1.0
      | Some d -> d -. Unix.gettimeofday ()
    in
    (match Unix.select reads [] [] timeout with
     | ready, _, _ -> `Ready ready
     | exception Unix.Unix_error (Unix.EINTR, _, _) -> select_ready ?deadline reads)
;;

let capture_until_closed ?(deadline = None) stdout_fd stderr_fd =
  Unix.set_nonblock stdout_fd;
  Unix.set_nonblock stderr_fd;
  let out = Buffer.create 256 in
  let err = Buffer.create 256 in
  let timed_out = ref false in
  let rec loop so se =
    if so || se
    then (
      let reads = (if so then [ stdout_fd ] else []) @ if se then [ stderr_fd ] else [] in
      match select_ready ?deadline reads with
      | `Expired -> timed_out := true
      | `Ready ready ->
        let so =
          so
          && ((not (List.mem stdout_fd ready))
              ||
              match read_available stdout_fd out with
              | `Open -> true
              | `Closed -> false)
        in
        let se =
          se
          && ((not (List.mem stderr_fd ready))
              ||
              match read_available stderr_fd err with
              | `Open -> true
              | `Closed -> false)
        in
        loop so se)
  in
  loop true true;
  !timed_out, Buffer.contents out, Buffer.contents err
;;

let signal_exit n = 128 + if n >= 0 then n else abs n

let status_to_exit_code = function
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n -> signal_exit n
  | Unix.WSTOPPED n -> signal_exit n
;;

let rec wait_reap pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_reap pid
;;

let rec wait_reap_wnohang pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> None
  | _, status -> Some status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_reap_wnohang pid
;;

let rec wait_poll ~deadline pid =
  match wait_reap_wnohang pid with
  | None ->
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0.0
    then `Timed_out
    else (
      (try ignore (Unix.select [] [] [] (Float.min remaining 0.05)) with
       | Unix.Unix_error (Unix.EINTR, _, _) -> ());
      wait_poll ~deadline pid)
  | Some status -> `Exited status
;;

let wait_for_exit ?deadline pid =
  match deadline with
  | None -> `Exited (wait_reap pid)
  | Some d -> wait_poll ~deadline:d pid
;;

let run ?(echo = false) c =
  match c.argv with
  | [] -> Error (Spawn_failed "empty argv")
  | prog :: _ ->
    if echo then echo_cmd c.argv c.redact;
    let cwd_result =
      match c.cwd with
      | None -> Ok None
      | Some dir ->
        let orig = Sys.getcwd () in
        (try
           Ok
             (Unix.chdir dir;
              Some orig)
         with
         | Unix.Unix_error (e, _, _) ->
           Error (Printf.sprintf "chdir %s: %s" dir (Unix.error_message e)))
    in
    (match cwd_result with
     | Error msg -> Error (Spawn_failed msg)
     | Ok saved_cwd ->
       let env_arr = environment c in
       let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
       let out_r, out_w = Unix.pipe ~cloexec:true () in
       let err_r, err_w = Unix.pipe ~cloexec:true () in
       let spawn_result =
         try
           let pid =
             Unix.create_process_env
               prog
               (Array.of_list c.argv)
               env_arr
               devnull
               out_w
               err_w
           in
           Ok pid
         with
         | Unix.Unix_error (e, fn, _) ->
           Error (Printf.sprintf "%s: %s" fn (Unix.error_message e))
       in
       close_noerr devnull;
       close_noerr out_w;
       close_noerr err_w;
       saved_cwd
       |> Option.iter (fun d ->
         try Unix.chdir d with
         | _ -> ());
       (match spawn_result with
        | Error msg ->
          close_noerr out_r;
          close_noerr err_r;
          Error (Spawn_failed msg)
        | Ok pid ->
          let deadline = Option.map (fun s -> Unix.gettimeofday () +. s) c.timeout_s in
          let finished = ref false in
          let kill_and_reap () =
            (try Unix.kill pid Sys.sigkill with
             | Unix.Unix_error _ -> ());
            try ignore (wait_reap pid) with
            | Unix.Unix_error _ -> ()
          in
          Fun.protect
            ~finally:(fun () ->
              if not !finished
              then (
                close_noerr out_r;
                close_noerr err_r;
                kill_and_reap ()))
            (fun () ->
               let timed_out, stdout, stderr =
                 capture_until_closed ~deadline out_r err_r
               in
               close_noerr out_r;
               close_noerr err_r;
               let exit_code =
                 if timed_out
                 then None
                 else (
                   match wait_for_exit ?deadline pid with
                   | `Timed_out -> None
                   | `Exited status -> Some (status_to_exit_code status))
               in
               finished := true;
               match exit_code with
               | None ->
                 kill_and_reap ();
                 Error (Timeout (Option.get c.timeout_s))
               | Some exit_code ->
                 completed
                   ~exit_code
                   ~stdout:(String.trim stdout)
                   ~stderr:(String.trim stderr))))
;;

type background = { pid : int }

let spawn ?output c =
  match c.argv with
  | [] -> Error (Spawn_failed "empty argv")
  | prog :: _ ->
    let env_arr = environment c in
    let devnull_in = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
    let out, close_out_fd =
      match output with
      | Some fd -> fd, false
      | None -> Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0, true
    in
    let spawned =
      match
        Unix.create_process_env prog (Array.of_list c.argv) env_arr devnull_in out out
      with
      | pid -> Ok { pid }
      | exception Unix.Unix_error (e, fn, _) ->
        Error (Spawn_failed (Printf.sprintf "%s: %s" fn (Unix.error_message e)))
    in
    close_noerr devnull_in;
    if close_out_fd then close_noerr out;
    spawned
;;

let resolve_program prog =
  if String.contains prog '/'
  then prog
  else (
    let path = Option.value (Sys.getenv_opt "PATH") ~default:"/usr/bin:/bin" in
    let rec search = function
      | [] -> prog
      | dir :: rest ->
        let candidate = Filename.concat dir prog in
        if Sys.file_exists candidate then candidate else search rest
    in
    search (String.split_on_char ':' path))
;;

let spawn_detached ?output c =
  match c.argv with
  | [] -> Error (Spawn_failed "empty argv")
  | prog :: _ as argv ->
    let program = resolve_program prog in
    let env_arr = environment c in
    let devnull_in = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
    let out =
      match output with
      | Some fd -> fd
      | None -> Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0
    in
    let exec_read, exec_write = Unix.pipe ~cloexec:true () in
    let started =
      match Unix.fork () with
      | 0 ->
        (try
           close_noerr exec_read;
           ignore (Unix.setsid ());
           (match c.cwd with
            | None | Some "" | Some "." -> ()
            | Some dir -> Unix.chdir dir);
           Unix.dup2 devnull_in Unix.stdin;
           Unix.dup2 out Unix.stdout;
           Unix.dup2 out Unix.stderr;
           close_noerr devnull_in;
           close_noerr out;
           Unix.execve program (Array.of_list argv) env_arr
         with
         | Unix.Unix_error (error, _, _) ->
           let message = Unix.error_message error in
           (try
              ignore (Unix.write_substring exec_write message 0 (String.length message))
            with
            | _ -> ());
           close_noerr exec_write;
           Unix._exit 127
         | _ ->
           let message = "the child could not start" in
           (try
              ignore (Unix.write_substring exec_write message 0 (String.length message))
            with
            | _ -> ());
           close_noerr exec_write;
           Unix._exit 127)
      | pid -> `Started pid
      | exception Unix.Unix_error (error, fn, _) ->
        `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message error))
    in
    close_noerr devnull_in;
    close_noerr out;
    (match started with
     | `Failed message ->
       close_noerr exec_read;
       close_noerr exec_write;
       Error (Spawn_failed message)
     | `Started pid ->
       close_noerr exec_write;
       let buffer = Bytes.create 256 in
       let count =
         match Unix.read exec_read buffer 0 (Bytes.length buffer) with
         | count -> count
         | exception Unix.Unix_error _ -> 0
       in
       close_noerr exec_read;
       if count = 0
       then Ok { pid }
       else (
         (try ignore (wait_reap pid) with
          | Unix.Unix_error _ -> ());
         Error (Spawn_failed (Bytes.sub_string buffer 0 count))))
;;

let pid { pid } = pid

let stop { pid } =
  (try Unix.kill pid Sys.sigterm with
   | Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [ Unix.WNOHANG ] pid) with
  | Unix.Unix_error _ -> ()
;;

let join { pid } =
  let rec wait () =
    match Unix.waitpid [] pid with
    | _, _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
    | exception Unix.Unix_error _ -> ()
  in
  wait ()
;;

let failure_message { exit_code; stdout; stderr } =
  match String.trim stderr, String.trim stdout with
  | "", "" -> Printf.sprintf "exited with code %d" exit_code
  | "", out -> out
  | err, _ -> err
;;

let run_shell ?(echo = false) cmd_str =
  if echo then Sol_cli_report.app "  $ %s" cmd_str;
  run ~echo:false (cmd [ "sh"; "-c"; cmd_str ])
;;
