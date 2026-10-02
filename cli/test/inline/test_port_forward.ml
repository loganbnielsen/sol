module P = Sol_cli_port_forward

let spec ?(name = "t") ?(target = "svc/a") ?(local_port = 18080) () : P.spec =
  { name; namespace = "ns"; target; local_port; remote_port = 80 }
;;

let ok = function
  | Ok v -> v
  | Error e -> Alcotest.fail e
;;

let rec wait_until ?(tries = 200) cond =
  if cond ()
  then true
  else if tries = 0
  then false
  else (
    Unix.sleepf 0.05;
    wait_until ~tries:(tries - 1) cond)
;;

let alive pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
;;

let write path text = Out_channel.with_open_text path (fun oc -> output_string oc text)

let hold_lock name =
  Sol_cli_state.ensure () |> Result.get_ok;
  let pid =
    Sol_cli_process.spawn
      (Sol_cli_process.cmd
         [ "setsid"; "flock"; Sol_cli_state.lock_file name; "sleep"; "30" ])
    |> Result.get_ok
    |> Sol_cli_process.pid
  in
  write (Sol_cli_state.pid_file name) (string_of_int pid);
  if not (wait_until (fun () -> P.is_running name)) then Alcotest.fail "lock not taken";
  pid
;;

let reap pid =
  (try Unix.kill (-pid) Sys.sigkill with
   | Unix.Unix_error _ -> ());
  ignore (Unix.waitpid [] pid)
;;

let test_record_round_trip () =
  P.stop_all ();
  let s = spec ~name:"round" () in
  ok (P.write_record s);
  let recorded, unreadable = P.records () in
  Alcotest.(check bool) "recorded as written" true (List.mem s recorded);
  Alcotest.(check (list string)) "nothing unreadable" [] unreadable;
  P.stop "round";
  Alcotest.(check bool) "stop removes the record" false (List.mem s (fst (P.records ())))
;;

let test_corrupt_record_is_reported () =
  Sol_cli_state.ensure () |> Result.get_ok;
  write (Sol_cli_state.record_file "corrupt") "{not json";
  let _, unreadable = P.records () in
  Alcotest.(check bool) "reported, not skipped" true (unreadable <> []);
  Sys.remove (Sol_cli_state.record_file "corrupt")
;;

let test_liveness_is_the_lock () =
  let name = "live" in
  ok (P.write_record (spec ~name ()));
  Alcotest.(check bool) "no holder, not running" false (P.is_running name);
  let pid = hold_lock name in
  Alcotest.(check bool) "held, running" true (P.is_running name);
  P.stop name;
  Alcotest.(check bool)
    "stop ends the whole group"
    true
    (wait_until (fun () -> not (P.is_running name)));
  reap pid
;;

let test_reused_pid_is_never_signalled () =
  let name = "reused" in
  ok (P.write_record (spec ~name ()));
  let bystander =
    Sol_cli_process.spawn (Sol_cli_process.cmd [ "sleep"; "30" ])
    |> Result.get_ok
    |> Sol_cli_process.pid
  in
  write (Sol_cli_state.pid_file name) (string_of_int bystander);
  P.stop name;
  Unix.sleepf 0.1;
  Alcotest.(check bool) "the bystander is untouched" true (alive bystander);
  Unix.kill bystander Sys.sigkill;
  ignore (Unix.waitpid [] bystander)
;;

let test_replace_conflicting () =
  P.stop_all ();
  let other = spec ~name:"other" ~target:"svc/old" () in
  let same = spec ~name:"same" ~target:"svc/new" ~local_port:18081 () in
  ok (P.write_record other);
  ok (P.write_record same);
  let pid = hold_lock "other" in
  let replaced =
    P.replace_conflicting ~local_port:18080 ~namespace:"ns" ~target:"svc/new"
  in
  Alcotest.(check (list string))
    "only the running forward for another target on the port"
    [ "other" ]
    (List.map (fun (pf : P.spec) -> pf.name) replaced);
  Alcotest.(check bool)
    "and it was stopped"
    true
    (wait_until (fun () -> not (P.is_running "other")));
  reap pid;
  P.stop_all ()
;;

let test_dead_forward_reports_its_log () =
  let name = "dead" in
  write (Sol_cli_state.log_file name) "one\n\ntwo\nthree\nfour\nfive\nsix\n";
  (match P.check_alive ~name with
   | P.Alive -> Alcotest.fail "nothing holds the lock"
   | P.Dead { log; log_tail } ->
     Alcotest.(check string) "log path" (Sol_cli_state.log_file name) log;
     Alcotest.(check (list string))
       "last five non-blank lines"
       [ "two"; "three"; "four"; "five"; "six" ]
       log_tail);
  Sys.remove (Sol_cli_state.log_file name)
;;

let test_start_and_stop_end_to_end () =
  let bin = Filename.concat (Sys.getcwd ()) "fake-kubectl-bin" in
  (try Unix.mkdir bin 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let marker = Filename.concat (Sys.getcwd ()) "fake-kubectl.pid" in
  write
    (Filename.concat bin "kubectl")
    (Printf.sprintf "#!/bin/sh\necho $$ > %s\nexec sleep 30\n" (Filename.quote marker));
  Unix.chmod (Filename.concat bin "kubectl") 0o755;
  let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (bin ^ ":" ^ path);
  let name = "e2e" in
  ok
    (P.start
       ~ctx:Sol_cli_kube_destination.local_context
       (spec ~name ~local_port:18090 ()));
  Alcotest.(check bool)
    "running once started"
    true
    (wait_until (fun () -> P.is_running name));
  Alcotest.(check bool) "kubectl ran" true (wait_until (fun () -> Sys.file_exists marker));
  let kubectl_pid =
    int_of_string (String.trim (In_channel.with_open_text marker In_channel.input_all))
  in
  Alcotest.(check bool)
    "recorded"
    true
    (List.exists (fun (pf : P.spec) -> pf.name = name) (fst (P.records ())));
  P.stop name;
  Alcotest.(check bool) "stopped" true (wait_until (fun () -> not (P.is_running name)));
  Alcotest.(check bool)
    "its kubectl is gone too"
    true
    (wait_until (fun () -> not (alive kubectl_pid)));
  Unix.putenv "PATH" path;
  Sys.remove marker
;;

let%test "records and liveness (REFAC-126): record round trip" = test_record_round_trip ()

let%test "records and liveness (REFAC-126): corrupt record reported" =
  test_corrupt_record_is_reported ()
;;

let%test "records and liveness (REFAC-126): liveness is the lock" =
  test_liveness_is_the_lock ()
;;

let%test "records and liveness (REFAC-126): a reused pid is never signalled" =
  test_reused_pid_is_never_signalled ()
;;

let%test "records and liveness (REFAC-126): replace conflicting" =
  test_replace_conflicting ()
;;

let%test "records and liveness (REFAC-126): dead forward reports its log" =
  test_dead_forward_reports_its_log ()
;;

let%test "records and liveness (REFAC-126): start and stop end to end" =
  test_start_and_stop_end_to_end ()
;;
