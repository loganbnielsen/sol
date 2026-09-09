type status = Exited of int | Signaled of int | Stopped of int
type result = { status : status; stdout : string; stderr : string }

(* ponytail: OCaml stores signals as -(posix_n) on Linux; abs gives the POSIX number *)
let signal_number n = abs n

let status_of_unix = function
  | Unix.WEXITED n -> Exited n
  | Unix.WSIGNALED n -> Signaled (signal_number n)
  | Unix.WSTOPPED n -> Stopped (signal_number n)

let status_to_exit_code = function
  | Exited n -> n
  | Signaled n -> 128 + n
  | Stopped n -> 128 + n

let exit_code r = status_to_exit_code r.status

let succeeded r =
  match r.status with
  | Exited 0 -> true
  | Exited _ | Signaled _ | Stopped _ -> false

let command_of_argv argv = String.concat " " (List.map Filename.quote argv)

let trim_result r =
  { r with stdout = String.trim r.stdout; stderr = String.trim r.stderr }

let read_available fd buf =
  let bytes = Bytes.create 4096 in
  match Unix.read fd bytes 0 (Bytes.length bytes) with
  | 0 -> `Closed
  | n ->
      Buffer.add_subbytes buf bytes 0 n;
      `Open
  | exception
      Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
      `Open

let capture_fds stdout_fd stderr_fd =
  Unix.set_nonblock stdout_fd;
  Unix.set_nonblock stderr_fd;
  let stdout_buf = Buffer.create 256 in
  let stderr_buf = Buffer.create 256 in
  let rec loop stdout_open stderr_open =
    if stdout_open || stderr_open then begin
      let reads =
        (if stdout_open then [ stdout_fd ] else [])
        @ if stderr_open then [ stderr_fd ] else []
      in
      let ready, _, _ = Unix.select reads [] [] (-1.0) in
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
      loop stdout_open stderr_open
    end
  in
  loop true true;
  {
    status = Exited 0;
    stdout = Buffer.contents stdout_buf;
    stderr = Buffer.contents stderr_buf;
  }

let close_noerr fd = try Unix.close fd with Unix.Unix_error _ -> ()

(* Run [argv] directly with Unix.create_process and capture stdout + stderr.
   No shell is involved, so metacharacters are passed as ordinary argument
   bytes. *)
let run_argv ?(echo = false) argv =
  match argv with
  | [] -> invalid_arg "Sol_process.run_argv: empty argv"
  | prog :: _ -> (
      if echo then Printf.printf "  $ %s\n%!" (command_of_argv argv);
      let stdin_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
      let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
      let stderr_r, stderr_w = Unix.pipe ~cloexec:true () in
      match
        Unix.create_process prog (Array.of_list argv) stdin_fd stdout_w stderr_w
      with
      | pid ->
          close_noerr stdin_fd;
          close_noerr stdout_w;
          close_noerr stderr_w;
          let captured = capture_fds stdout_r stderr_r in
          close_noerr stdout_r;
          close_noerr stderr_r;
          let status = status_of_unix (Unix.waitpid [] pid |> snd) in
          trim_result { captured with status }
      | exception Unix.Unix_error (err, fn, arg) ->
          close_noerr stdin_fd;
          close_noerr stdout_r;
          close_noerr stdout_w;
          close_noerr stderr_r;
          close_noerr stderr_w;
          {
            status = Exited 127;
            stdout = "";
            stderr =
              Printf.sprintf "%s: %s %s" fn arg (Unix.error_message err)
              |> String.trim;
          })

(* Run [cmd] via /bin/sh and capture stdout + stderr.
   Reads stdout then stderr sequentially; safe for the small outputs typical
   of CLI tools (kubectl, helm, git, docker).  Do not use for commands that
   stream MB+ to stderr while producing stdout. *)
let run_shell ?(echo = false) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  let ic, oc, ec = Unix.open_process_full cmd (Unix.environment ()) in
  close_out oc;
  let stdout = In_channel.input_all ic in
  let stderr = In_channel.input_all ec in
  let status = status_of_unix (Unix.close_process_full (ic, oc, ec)) in
  { status; stdout = String.trim stdout; stderr = String.trim stderr }

(* Capture stdout lines; stderr goes to /dev/null.
   Uses Unix.open_process_in so no temp file is needed. *)
let lines_shell ?(echo = false) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  let ic = Unix.open_process_in (cmd ^ " 2>/dev/null") in
  let content = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  List.filter
    (fun s -> s <> "")
    (String.split_on_char '\n' (String.trim content))

(* Capture stdout as a trimmed string; stderr goes to /dev/null. *)
let output_shell ?(echo = false) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  let ic = Unix.open_process_in (cmd ^ " 2>/dev/null") in
  let s = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  String.trim s

(* Run and return exit code only; does not capture output. *)
let run_shell_rc ?(echo = true) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  Sys.command cmd

(* Run and fail with an informative message if exit code is non-zero. *)
let run_shell_ok ?(echo = true) cmd =
  let rc = run_shell_rc ~echo cmd in
  if rc <> 0 then
    failwith (Printf.sprintf "command failed (exit %d): %s" rc cmd)
