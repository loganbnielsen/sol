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

let read_file path =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  with
  | _ -> ""
;;

let remove_quietly path =
  try Sys.remove path with
  | _ -> ()
;;

(* A child writes its own stdout and stderr to its own file, so three concurrent
   installs never interleave in a way the reader has to disentangle, and the
   output survives a failure. [Unix._exit] rather than [exit]: the parent's
   [at_exit] handlers (stopping port-forwards, for one) must not run once per
   child. *)
let spawn ~index install =
  let log = Filename.temp_file (Printf.sprintf "sol-local-%d-" index) ".log" in
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  match Unix.fork () with
  | 0 ->
    Unix.dup2 fd Unix.stdout;
    Unix.dup2 fd Unix.stderr;
    Unix.close fd;
    let code =
      match install.run () with
      | Ok () -> 0
      | Error msg ->
        prerr_endline msg;
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
      Printf.printf "  %-14s installing...\n%!" install.label;
      true
  in
  let rec pump () =
    (* Fill the slots, unless something has already failed: a failure stops new
       installs from starting, so a bad component does not get five more
       half-installed companions, while the ones already running are waited for
       rather than abandoned. *)
    let rec fill () =
      if !failures = [] && !started < max_in_flight && start_one () then fill ()
    in
    fill ();
    if !running = []
    then ()
    else (
      let pid, status = Unix.waitpid [] (-1) in
      match List.partition (fun c -> c.child_pid = pid) !running with
      | [], _ ->
        (* Not one of ours: no other waiter exists in this process at this
           point, so this cannot happen -- but reaping it and carrying on is
           still better than treating an unknown child as a component. *)
        pump ()
      | child :: _, others ->
        running := others;
        decr started;
        (match status with
         | Unix.WEXITED 0 -> Printf.printf "  %-14s ok\n%!" child.child_label
         | Unix.WEXITED n ->
           Printf.printf "  %-14s FAILED (exit %d)\n%!" child.child_label n;
           failures
           := (child.child_label, child.child_log, child.child_index) :: !failures
         | Unix.WSIGNALED n | Unix.WSTOPPED n ->
           Printf.printf "  %-14s FAILED (signal %d)\n%!" child.child_label n;
           failures
           := (child.child_label, child.child_log, child.child_index) :: !failures);
        pump ())
  in
  pump ();
  let not_started = List.map (fun (_, install) -> install.label) !queue in
  let failures = List.sort (fun (_, _, a) (_, _, b) -> compare a b) !failures in
  List.iter
    (fun (label, log, _) ->
       let output = read_file log in
       if output <> ""
       then Printf.eprintf "\n--- %s output ---\n%s%!" label output
       else Printf.eprintf "\n--- %s failed with no output ---\n%!" label)
    failures;
  (* Every log is temporary: the failing ones have just been printed, and the
     successful ones said all they had to say in their progress line. *)
  List.iter remove_quietly !logs;
  let failed_labels = List.map (fun (label, _, _) -> label) failures in
  if failed_labels = [] && not_started = []
  then Ok ()
  else Error (describe_failures failed_labels not_started)
;;
