module P = Sol_cli_port_forward

let run_id = string_of_int (Unix.getpid ())
let unique base = base ^ "-" ^ run_id

let spec ?(name = "t") ?(target = "svc/a") ?(local_port = 18080) () : P.spec =
  { name; namespace = "ns"; target; local_port; remote_port = 80 }
;;

let ok = function
  | Ok v -> v
  | Error e -> Windtrap.fail e
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
  let ready_r, ready_w = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    let report message code =
      (try
         ignore (Unix.write_substring ready_w message 0 (String.length message));
         Unix.close ready_w
       with
       | _ -> ());
      Unix._exit code
    in
    (try
       Unix.close ready_r;
       ignore (Unix.setsid ());
       let fd =
         Unix.openfile (Sol_cli_state.lock_file name) [ Unix.O_RDWR; Unix.O_CREAT ] 0o600
       in
       match Unix.lockf fd Unix.F_TLOCK 0 with
       | () ->
         ignore (Unix.write_substring ready_w "acquired" 0 8);
         Unix.close ready_w;
         Unix.sleepf 30.;
         Unix._exit 0
       | exception Unix.Unix_error (e, _, _) -> report (Unix.error_message e) 2
     with
     | e -> report (Printexc.to_string e) 2)
  | pid ->
    Unix.close ready_w;
    let buffer = Bytes.create 64 in
    let got =
      try Unix.read ready_r buffer 0 64 with
      | Unix.Unix_error _ -> 0
    in
    Unix.close ready_r;
    write (Sol_cli_state.pid_file name) (string_of_int pid);
    let message = Bytes.sub_string buffer 0 got in
    if message <> "acquired"
    then Windtrap.failf "the forked holder did not take the lock (%s)" message;
    if not (P.is_running name)
    then Windtrap.fail "the forked holder holds the lock but is_running reports it dead";
    pid
;;

let reap pid =
  (try Unix.kill (-pid) Sys.sigkill with
   | Unix.Unix_error _ -> ());
  ignore (Unix.waitpid [] pid)
;;

let test_record_round_trip () =
  P.stop_all ();
  let name = unique "round" in
  let s = spec ~name () in
  ok (P.write_record s);
  let recorded, unreadable = P.records () in
  Windtrap.equal Windtrap.bool ~msg:"recorded as written" true (List.mem s recorded);
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg:"nothing unreadable" [] unreadable;
  P.stop name;
  Windtrap.equal
    Windtrap.bool
    ~msg:"stop removes the record"
    false
    (List.mem s (fst (P.records ())))
;;

let test_corrupt_record_is_reported () =
  Sol_cli_state.ensure () |> Result.get_ok;
  let name = unique "corrupt" in
  write (Sol_cli_state.record_file name) "{not json";
  let _, unreadable = P.records () in
  Windtrap.equal Windtrap.bool ~msg:"reported, not skipped" true (unreadable <> []);
  Sys.remove (Sol_cli_state.record_file name)
;;

let test_liveness_is_the_lock () =
  let name = unique "live" in
  ok (P.write_record (spec ~name ()));
  Windtrap.equal Windtrap.bool ~msg:"no holder, not running" false (P.is_running name);
  let pid = hold_lock name in
  Windtrap.equal Windtrap.bool ~msg:"held, running" true (P.is_running name);
  P.stop name;
  Windtrap.equal
    Windtrap.bool
    ~msg:"stop ends the whole group"
    true
    (wait_until (fun () -> not (P.is_running name)));
  reap pid
;;

let test_reused_pid_is_never_signalled () =
  let name = unique "reused" in
  ok (P.write_record (spec ~name ()));
  let bystander =
    Sol_cli_process.spawn (Sol_cli_process.cmd [ "sleep"; "30" ])
    |> Result.get_ok
    |> Sol_cli_process.pid
  in
  write (Sol_cli_state.pid_file name) (string_of_int bystander);
  P.stop name;
  Unix.sleepf 0.1;
  Windtrap.equal Windtrap.bool ~msg:"the bystander is untouched" true (alive bystander);
  Unix.kill bystander Sys.sigkill;
  ignore (Unix.waitpid [] bystander)
;;

let test_replace_conflicting () =
  P.stop_all ();
  let other_name = unique "other" in
  let same_name = unique "same" in
  let other = spec ~name:other_name ~target:"svc/old" () in
  let same = spec ~name:same_name ~target:"svc/new" ~local_port:18081 () in
  ok (P.write_record other);
  ok (P.write_record same);
  let pid = hold_lock other_name in
  let replaced =
    P.replace_conflicting ~local_port:18080 ~namespace:"ns" ~target:"svc/new"
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"only the running forward for another target on the port"
    [ other_name ]
    (List.map (fun (pf : P.spec) -> pf.name) replaced);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and it was stopped"
    true
    (wait_until (fun () -> not (P.is_running other_name)));
  reap pid;
  P.stop_all ()
;;

let test_dead_forward_reports_its_log () =
  let name = unique "dead" in
  write (Sol_cli_state.log_file name) "one\n\ntwo\nthree\nfour\nfive\nsix\n";
  (match P.check_alive ~name with
   | P.Alive -> Windtrap.fail "nothing holds the lock"
   | P.Dead { log; log_tail } ->
     Windtrap.equal Windtrap.string ~msg:"log path" (Sol_cli_state.log_file name) log;
     Windtrap.equal
       (Windtrap.list Windtrap.string)
       ~msg:"last five non-blank lines"
       [ "two"; "three"; "four"; "five"; "six" ]
       log_tail);
  Sys.remove (Sol_cli_state.log_file name)
;;

let test_fail_streak_policy () =
  Windtrap.equal
    Windtrap.int
    ~msg:"a quick failure starts the streak"
    1
    (P.next_fail_streak ~streak:0 ~elapsed_s:1.);
  Windtrap.equal
    Windtrap.int
    ~msg:"quick failures accumulate"
    4
    (P.next_fail_streak ~streak:3 ~elapsed_s:0.);
  Windtrap.equal
    Windtrap.int
    ~msg:"a lasting run resets the streak"
    0
    (P.next_fail_streak ~streak:7 ~elapsed_s:30.);
  Windtrap.equal
    Windtrap.int
    ~msg:"exactly the threshold is a lasting run"
    0
    (P.next_fail_streak ~streak:2 ~elapsed_s:P.quick_fail_threshold_s);
  Windtrap.equal
    Windtrap.bool
    ~msg:"below the limit does not give up"
    false
    (P.exhausted (P.max_fail_streak - 1));
  let streak =
    List.fold_left
      (fun streak _ -> P.next_fail_streak ~streak ~elapsed_s:0.)
      0
      (List.init P.max_fail_streak Fun.id)
  in
  Windtrap.equal Windtrap.int ~msg:"N quick failures reach N" P.max_fail_streak streak;
  Windtrap.equal Windtrap.bool ~msg:"and that gives up" true (P.exhausted streak)
;;

let sol_binary () =
  let candidates =
    [ Filename.concat (Sys.getcwd ()) "../../bin/main.exe"
    ; Filename.concat (Source_root.find ()) "_build/default/cli/bin/main.exe"
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Windtrap.fail "cannot locate the sol binary for the port-forward supervisor"
;;

let test_start_and_stop_end_to_end () =
  let bin = Filename.concat (Sys.getcwd ()) "fake-kubectl-bin" in
  (try Unix.mkdir bin 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let marker =
    Filename.concat (Sys.getcwd ()) (Printf.sprintf "fake-kubectl-%s.pid" run_id)
  in
  write
    (Filename.concat bin "kubectl")
    (Printf.sprintf "#!/bin/sh\necho $$ > %s\nexec sleep 30\n" (Filename.quote marker));
  Unix.chmod (Filename.concat bin "kubectl") 0o755;
  let name = unique "e2e" in
  let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" path;
      (try Sys.remove marker with
       | Sys_error _ -> ());
      P.stop name)
    (fun () ->
       Unix.putenv "PATH" (bin ^ ":" ^ path);
       ok
         (P.start
            ~supervisor:(sol_binary ())
            ~ctx:Sol_cli_kube_destination.local_context
            (spec ~name ~local_port:18090 ()));
       Windtrap.equal
         Windtrap.bool
         ~msg:"running once started"
         true
         (wait_until (fun () -> P.is_running name));
       Windtrap.equal
         Windtrap.bool
         ~msg:"kubectl ran"
         true
         (wait_until (fun () -> Sys.file_exists marker));
       let kubectl_pid =
         int_of_string
           (String.trim (In_channel.with_open_text marker In_channel.input_all))
       in
       Windtrap.equal
         Windtrap.bool
         ~msg:"recorded"
         true
         (List.exists (fun (pf : P.spec) -> pf.name = name) (fst (P.records ())));
       P.stop name;
       Windtrap.equal
         Windtrap.bool
         ~msg:"stopped"
         true
         (wait_until (fun () -> not (P.is_running name)));
       Windtrap.equal
         Windtrap.bool
         ~msg:"its kubectl is gone too"
         true
         (wait_until (fun () -> not (alive kubectl_pid))))
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

let%test "port-forward policy: the fail streak and its limit" = test_fail_streak_policy ()
