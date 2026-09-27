let max_in_flight_default = 3

type install =
  { label : string
  ; run : unit -> (unit, string) result
  }

type child =
  { child_label : string
  ; child_index : int
  ; child_pid : int
  ; child_log : string
  }

let spawn ~index install =
  let log = Filename.temp_file (Printf.sprintf "sol-local-%d-" index) ".log" in
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  flush stdout;
  flush stderr;
  match Unix.fork () with
  | 0 ->
    Unix.dup2 fd Unix.stdout;
    Unix.dup2 fd Unix.stderr;
    Unix.close fd;
    let code =
      match install.run () with
      | Ok () -> 0
      | Error msg ->
        Sol_cli_report.err "%s" msg;
        1
    in
    (try flush stdout with
     | _ -> ());
    (try flush stderr with
     | _ -> ());
    Unix._exit code
  | pid ->
    Unix.close fd;
    { child_label = install.label; child_index = index; child_pid = pid; child_log = log }
;;

let describe_failures failed_labels not_started =
  let failed =
    failed_labels
    |> List.map (fun label -> Printf.sprintf "%s failed" label)
    |> String.concat ", "
  in
  match not_started with
  | [] -> Printf.sprintf "local infrastructure installs: %s" failed
  | labels ->
    Printf.sprintf
      "local infrastructure installs: %s; not attempted (an earlier install failed): %s"
      failed
      (String.concat ", " labels)
;;

let run_bounded ?(max_in_flight = max_in_flight_default) installs =
  if max_in_flight < 1
  then invalid_arg "Sol_cli_local_infra.run_bounded: max_in_flight < 1";
  let queue = ref (List.mapi (fun i install -> i, install) installs) in
  let running = ref [] in
  let failures = ref [] in
  let logs = ref [] in
  let started = ref 0 in
  let start_one () =
    match !queue with
    | [] -> false
    | (index, install) :: rest ->
      queue := rest;
      incr started;
      let child = spawn ~index install in
      running := child :: !running;
      logs := child.child_log :: !logs;
      Sol_cli_report.app "  %-14s installing..." install.label;
      true
  in
  let rec pump () =
    let rec fill () =
      if !failures = [] && !started < max_in_flight && start_one () then fill ()
    in
    fill ();
    if !running = []
    then ()
    else (
      let pid, status = Unix.waitpid [] (-1) in
      match List.partition (fun c -> c.child_pid = pid) !running with
      | [], _ -> pump ()
      | child :: _, others ->
        running := others;
        decr started;
        (match status with
         | Unix.WEXITED 0 -> Sol_cli_report.app "  %-14s ok" child.child_label
         | Unix.WEXITED n ->
           Sol_cli_report.app "  %-14s FAILED (exit %d)" child.child_label n;
           failures
           := (child.child_label, child.child_log, child.child_index) :: !failures
         | Unix.WSIGNALED n | Unix.WSTOPPED n ->
           Sol_cli_report.app "  %-14s FAILED (signal %d)" child.child_label n;
           failures
           := (child.child_label, child.child_log, child.child_index) :: !failures);
        pump ())
  in
  pump ();
  let not_started = List.map (fun (_, install) -> install.label) !queue in
  let failures = List.sort (fun (_, _, a) (_, _, b) -> compare a b) !failures in
  failures
  |> List.iter (fun (label, log, _) ->
    match In_channel.with_open_bin log In_channel.input_all with
    | exception Sys_error message ->
      Sol_cli_report.err
        "\n--- %s failed; its log could not be read: %s ---"
        label
        message
    | "" -> Sol_cli_report.err "\n--- %s failed with no output ---" label
    | output ->
      Sol_cli_report.err_block (Printf.sprintf "\n--- %s output ---\n%s" label output));
  !logs
  |> List.iter (fun log ->
    Sol_cli_fs.remove_if_present log
    |> Result.iter_error (Sol_cli_report.warn "warning: could not remove %s"));
  let failed_labels = List.map (fun (label, _, _) -> label) failures in
  if failed_labels = [] && not_started = []
  then Ok ()
  else Error (describe_failures failed_labels not_started)
;;
