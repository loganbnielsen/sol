(* REFAC-126: port-forwards are records plus a lock. These tests hold the lock
   with a real [flock] in a background process instead of starting kubectl. The
   state directory is the test's own ($XDG_DATA_HOME, set for every action here). *)

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

(* A stand-in for a running forward: a session leader holding its lock, with its
   pid recorded where the wrapper would write it. *)
let hold_lock name =
  Sol_cli_state.ensure ();
  let pid =
    Unix.create_process
      "setsid"
      [| "setsid"; "flock"; Sol_cli_state.lock_file name; "sleep"; "30" |]
      Unix.stdin
      Unix.stdout
      Unix.stderr
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
  Sol_cli_state.ensure ();
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

(* The pid-reuse case: a record whose pid now belongs to an unrelated process.
   The lock is not held, so the process is never signalled. *)
let test_reused_pid_is_never_signalled () =
  let name = "reused" in
  ok (P.write_record (spec ~name ()));
  let bystander =
    Unix.create_process "sleep" [| "sleep"; "30" |] Unix.stdin Unix.stdout Unix.stderr
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

(* The real wrapper script, with a fake kubectl that stays up the way a working
   forward does: [start] takes the lock, and [stop] ends the wrapper *and* its
   kubectl -- which the old per-pid kill could leave holding the port. *)
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

let () =
  (* These tests write and stop forwards in Sol's state directory, so they refuse to
     run against the operator's own: dune gives every action here a private
     XDG_DATA_HOME. *)
  if Sys.getenv_opt "XDG_DATA_HOME" = None
  then (
    prerr_endline
      "test_port_forward: run it through dune (it needs a private XDG_DATA_HOME)";
    exit 2);
  Alcotest.run
    "sol_cli_port_forward"
    [ ( "records and liveness (REFAC-126)"
      , [ Alcotest.test_case "record round trip" `Quick test_record_round_trip
        ; Alcotest.test_case
            "corrupt record reported"
            `Quick
            test_corrupt_record_is_reported
        ; Alcotest.test_case "liveness is the lock" `Quick test_liveness_is_the_lock
        ; Alcotest.test_case
            "a reused pid is never signalled"
            `Quick
            test_reused_pid_is_never_signalled
        ; Alcotest.test_case "replace conflicting" `Quick test_replace_conflicting
        ; Alcotest.test_case
            "dead forward reports its log"
            `Quick
            test_dead_forward_reports_its_log
        ; Alcotest.test_case
            "start and stop end to end"
            `Quick
            test_start_and_stop_end_to_end
        ] )
    ]
;;
