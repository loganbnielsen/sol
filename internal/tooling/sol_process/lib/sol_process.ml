type status =
  | Exited of int
  | Signaled of int
  | Stopped of int

type result =
  { status : status
  ; stdout : string
  ; stderr : string
  }

let signal_number n = abs n

let status_of_unix = function
  | Unix.WEXITED n -> Exited n
  | Unix.WSIGNALED n -> Signaled (signal_number n)
  | Unix.WSTOPPED n -> Stopped (signal_number n)
;;

let status_to_exit_code = function
  | Exited n -> n
  | Signaled n -> 128 + n
  | Stopped n -> 128 + n
;;

let exit_code r = status_to_exit_code r.status

let succeeded r =
  match r.status with
  | Exited 0 -> true
  | Exited _ | Signaled _ | Stopped _ -> false
;;

let command_of_argv argv = String.concat " " (List.map Filename.quote argv)

let trim_result r =
  { r with stdout = String.trim r.stdout; stderr = String.trim r.stderr }
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

let rec select_ready reads =
  match Unix.select reads [] [] (-1.0) with
  | ready -> ready
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> select_ready reads
;;

let capture_fds stdout_fd stderr_fd =
  Unix.set_nonblock stdout_fd;
  Unix.set_nonblock stderr_fd;
  let stdout_buf = Buffer.create 256 in
  let stderr_buf = Buffer.create 256 in
  let rec loop stdout_open stderr_open =
    if stdout_open || stderr_open
    then (
      let reads =
        (if stdout_open then [ stdout_fd ] else [])
        @ if stderr_open then [ stderr_fd ] else []
      in
      let ready, _, _ = select_ready reads in
      let stdout_open =
        stdout_open
        && ((not (List.mem stdout_fd ready))
            ||
            match read_available stdout_fd stdout_buf with
            | `Open -> true
            | `Closed -> false)
      in
      let stderr_open =
        stderr_open
        && ((not (List.mem stderr_fd ready))
            ||
            match read_available stderr_fd stderr_buf with
            | `Open -> true
            | `Closed -> false)
      in
      loop stdout_open stderr_open)
  in
  loop true true;
  { status = Exited 0
  ; stdout = Buffer.contents stdout_buf
  ; stderr = Buffer.contents stderr_buf
  }
;;

let close_noerr fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let rec wait_reap pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_reap pid
;;

let spawn_error fn arg err =
  Printf.sprintf "%s: %s %s" fn arg (Unix.error_message err) |> String.trim
;;

let run_argv ?(echo = false) ?(stream = false) argv =
  match argv with
  | [] -> invalid_arg "Sol_process.run_argv: empty argv"
  | prog :: _ ->
    if echo then Printf.printf "  $ %s\n%!" (command_of_argv argv);
    let stdin_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
    if stream
    then (
      match
        Unix.create_process prog (Array.of_list argv) stdin_fd Unix.stdout Unix.stderr
      with
      | pid ->
        close_noerr stdin_fd;
        { status = status_of_unix (wait_reap pid); stdout = ""; stderr = "" }
      | exception Unix.Unix_error (err, fn, arg) ->
        close_noerr stdin_fd;
        { status = Exited 127; stdout = ""; stderr = spawn_error fn arg err })
    else (
      let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
      let stderr_r, stderr_w = Unix.pipe ~cloexec:true () in
      (match Unix.create_process prog (Array.of_list argv) stdin_fd stdout_w stderr_w with
       | pid ->
         close_noerr stdin_fd;
         close_noerr stdout_w;
         close_noerr stderr_w;
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
               close_noerr stdout_r;
               close_noerr stderr_r;
               kill_and_reap ()))
           (fun () ->
              let captured = capture_fds stdout_r stderr_r in
              close_noerr stdout_r;
              close_noerr stderr_r;
              let status = status_of_unix (wait_reap pid) in
              finished := true;
              trim_result { captured with status })
       | exception Unix.Unix_error (err, fn, arg) ->
         close_noerr stdin_fd;
         close_noerr stdout_r;
         close_noerr stdout_w;
         close_noerr stderr_r;
         close_noerr stderr_w;
         { status = Exited 127; stdout = ""; stderr = spawn_error fn arg err }))
;;

let run_shell ?(echo = false) ?(stream = false) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  run_argv ~echo:false ~stream [ "sh"; "-c"; cmd ]
;;

let failure_message r =
  match String.trim r.stderr with
  | "" -> Printf.sprintf "exited with code %d" (exit_code r)
  | said -> Printf.sprintf "exited with code %d: %s" (exit_code r) said
;;

let nonempty_lines s =
  List.filter (fun s -> s <> "") (String.split_on_char '\n' (String.trim s))
;;

let lines_shell ?(echo = false) cmd = nonempty_lines (run_shell ~echo cmd).stdout
let output_shell ?(echo = false) cmd = String.trim (run_shell ~echo cmd).stdout

let lines_shell_checked ?(echo = false) cmd =
  let r = run_shell ~echo cmd in
  if succeeded r then Ok (nonempty_lines r.stdout) else Error r
;;

let output_shell_checked ?(echo = false) cmd =
  let r = run_shell ~echo cmd in
  if succeeded r then Ok (String.trim r.stdout) else Error r
;;

let run_shell_rc ?(echo = true) cmd = exit_code (run_shell ~stream:true ~echo cmd)

let run_shell_ok ?(echo = true) cmd =
  let r = run_shell ~echo cmd in
  if not (succeeded r)
  then failwith (Printf.sprintf "command failed (exit %d): %s" (exit_code r) cmd)
;;
