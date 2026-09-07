type cmd = {
  argv    : string list;
  cwd     : string option;
  env     : (string * string) list option;
  timeout_s : float option;
  redact  : string list;
}

type result = {
  exit_code : int;
  stdout    : string;
  stderr    : string;
}

type error =
  | Spawn_failed  of string
  | Non_zero      of { exit_code : int; stderr : string }
  | Timeout       of float

let cmd ?cwd ?env ?timeout_s ?(redact = []) argv =
  { argv; cwd; env; timeout_s; redact }

let error_to_string = function
  | Spawn_failed msg -> Printf.sprintf "spawn failed: %s" msg
  | Non_zero { exit_code; stderr } ->
    if stderr = "" then Printf.sprintf "exited with code %d" exit_code
    else Printf.sprintf "exited with code %d: %s" exit_code stderr
  | Timeout s -> Printf.sprintf "timed out after %.1fs" s

let apply_redactions redact s =
  List.fold_left (fun acc secret ->
    if secret = "" then acc
    else
      let buf = Buffer.create (String.length acc) in
      let slen = String.length secret and alen = String.length acc in
      let rec loop i =
        if i > alen - slen then
          Buffer.add_substring buf acc i (alen - i)
        else if String.sub acc i slen = secret then begin
          Buffer.add_string buf "***";
          loop (i + slen)
        end else begin
          Buffer.add_char buf acc.[i];
          loop (i + 1)
        end
      in
      loop 0;
      Buffer.contents buf
  ) s redact

let echo_cmd argv redact =
  let display = String.concat " " (List.map Filename.quote argv) in
  Printf.printf "  $ %s\n%!" (apply_redactions redact display)

let merge_env extras =
  let current = Unix.environment () in
  let extra_keys = List.map fst extras in
  let filtered = Array.to_list current
    |> List.filter (fun entry ->
      let key = match String.index_opt entry '=' with
        | Some i -> String.sub entry 0 i
        | None   -> entry
      in
      not (List.mem key extra_keys))
  in
  Array.of_list (filtered @ List.map (fun (k, v) -> k ^ "=" ^ v) extras)

let close_noerr fd =
  try Unix.close fd with Unix.Unix_error _ -> ()

let read_available fd buf =
  let bytes = Bytes.create 4096 in
  match Unix.read fd bytes 0 (Bytes.length bytes) with
  | 0 -> `Closed
  | n ->
    Buffer.add_subbytes buf bytes 0 n;
    `Open
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
    `Open

let capture_until_closed ?(deadline = None) stdout_fd stderr_fd =
  Unix.set_nonblock stdout_fd;
  Unix.set_nonblock stderr_fd;
  let out = Buffer.create 256 in
  let err = Buffer.create 256 in
  let timed_out = ref false in
  let rec loop so se =
    if so || se then begin
      let timeout = match deadline with
        | None -> -1.0
        | Some d ->
          let remaining = d -. Unix.gettimeofday () in
          if remaining <= 0.0 then begin timed_out := true; 0.0 end
          else remaining
      in
      if !timed_out then ()
      else begin
        let reads =
          (if so then [stdout_fd] else [])
          @ (if se then [stderr_fd] else [])
        in
        let ready, _, _ = Unix.select reads [] [] timeout in
        if ready = [] && deadline <> None then
          timed_out := true
        else begin
          let so =
            so &&
            (not (List.mem stdout_fd ready)
             || match read_available stdout_fd out with
                | `Open -> true
                | `Closed -> false)
          in
          let se =
            se &&
            (not (List.mem stderr_fd ready)
             || match read_available stderr_fd err with
                | `Open -> true
                | `Closed -> false)
          in
          loop so se
        end
      end
    end
  in
  loop true true;
  (!timed_out, Buffer.contents out, Buffer.contents err)

let signal_exit n = 128 + (if n >= 0 then n else abs n)

let status_to_exit_code = function
  | Unix.WEXITED n   -> n
  | Unix.WSIGNALED n -> signal_exit n
  | Unix.WSTOPPED  n -> signal_exit n

let run ?(echo = false) c =
  match c.argv with
  | [] -> Error (Spawn_failed "empty argv")
  | prog :: _ ->
    if echo then echo_cmd c.argv c.redact;
    let cwd_result = match c.cwd with
      | None -> Ok None
      | Some dir ->
        let orig = Sys.getcwd () in
        try Ok (Unix.chdir dir; Some orig)
        with Unix.Unix_error (e, _, _) ->
          Error (Printf.sprintf "chdir %s: %s" dir (Unix.error_message e))
    in
    match cwd_result with
    | Error msg -> Error (Spawn_failed msg)
    | Ok saved_cwd ->
      let env_arr = match c.env with
        | None -> Unix.environment ()
        | Some extras -> merge_env extras
      in
      let devnull = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
      let out_r, out_w = Unix.pipe ~cloexec:true () in
      let err_r, err_w = Unix.pipe ~cloexec:true () in
      let spawn_result =
        (try
           let pid =
             Unix.create_process_env prog (Array.of_list c.argv) env_arr
               devnull out_w err_w
           in
           Ok pid
         with Unix.Unix_error (e, fn, _) ->
           Error (Printf.sprintf "%s: %s" fn (Unix.error_message e)))
      in
      close_noerr devnull;
      close_noerr out_w;
      close_noerr err_w;
      (match saved_cwd with Some d -> (try Unix.chdir d with _ -> ()) | None -> ());
      match spawn_result with
      | Error msg ->
        close_noerr out_r;
        close_noerr err_r;
        Error (Spawn_failed msg)
      | Ok pid ->
        let deadline = Option.map (fun s -> Unix.gettimeofday () +. s) c.timeout_s in
        let (timed_out, stdout, stderr) = capture_until_closed ~deadline out_r err_r in
        close_noerr out_r;
        close_noerr err_r;
        if timed_out then begin
          (try Unix.kill pid Sys.sigkill with _ -> ());
          ignore (Unix.waitpid [] pid);
          Error (Timeout (Option.get c.timeout_s))
        end else begin
          let exit_code = status_to_exit_code (Unix.waitpid [] pid |> snd) in
          Ok { exit_code; stdout = String.trim stdout; stderr = String.trim stderr }
        end

let run_ok ?(echo = false) c =
  match run ~echo c with
  | Error _ as e -> e
  | Ok r when r.exit_code = 0 -> Ok ()
  | Ok r -> Error (Non_zero { exit_code = r.exit_code; stderr = r.stderr })

let run_shell ?(echo = false) cmd_str =
  if echo then Printf.printf "  $ %s\n%!" cmd_str;
  try
    let ic, oc, ec = Unix.open_process_full cmd_str (Unix.environment ()) in
    close_out oc;
    let stdout = In_channel.input_all ic in
    let stderr = In_channel.input_all ec in
    let status = Unix.close_process_full (ic, oc, ec) in
    let exit_code = status_to_exit_code status in
    Ok { exit_code; stdout = String.trim stdout; stderr = String.trim stderr }
  with Unix.Unix_error (e, fn, _) ->
    Error (Spawn_failed (Printf.sprintf "%s: %s" fn (Unix.error_message e)))
