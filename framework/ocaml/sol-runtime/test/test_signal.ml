let await_resolved env promise =
  Eio.Time.with_timeout_exn env#clock 5.0 (fun () -> Eio.Promise.await promise) |> ignore
;;

let test_sigterm_resolves_promise () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let promise, resolver = Eio.Promise.create () in
  Sol_runtime.install_signal_handler ~sw resolver;
  Unix.kill (Unix.getpid ()) Sys.sigterm;
  await_resolved env promise
;;

let test_sigint_resolves_promise () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let promise, resolver = Eio.Promise.create () in
  Sol_runtime.install_signal_handler ~sw resolver;
  Unix.kill (Unix.getpid ()) Sys.sigint;
  await_resolved env promise
;;

let test_one_signal_reaches_every_registration () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let first, first_r = Eio.Promise.create () in
  let second, second_r = Eio.Promise.create () in
  Sol_runtime.install_signal_handler ~sw first_r;
  Sol_runtime.install_signal_handler ~sw second_r;
  Unix.kill (Unix.getpid ()) Sys.sigterm;
  await_resolved env first;
  await_resolved env second
;;

let test_disposition_restored_after_the_switch_ends () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let _promise, resolver = Eio.Promise.create () in
      Sol_runtime.install_signal_handler ~sw resolver));
  let now = Sys.signal Sys.sigterm Sys.Signal_default in
  Windtrap.equal
    Windtrap.bool
    ~msg:"SIGTERM is back to the default disposition"
    true
    (now = Sys.Signal_default)
;;

let concurrent_registration_child () =
  let leaked = ref false in
  let round = ref 0 in
  while (not !leaked) && !round < 2000 do
    incr round;
    let entered = Atomic.make 0 in
    let installed = Atomic.make 0 in
    let work () =
      Eio_main.run (fun _env ->
        Eio.Switch.run (fun sw ->
          ignore (Atomic.fetch_and_add entered 1);
          while Atomic.get entered < 2 do
            Domain.cpu_relax ()
          done;
          let _promise, resolver = Eio.Promise.create () in
          Sol_runtime.install_signal_handler ~sw resolver;
          ignore (Atomic.fetch_and_add installed 1);
          while Atomic.get installed < 2 do
            Domain.cpu_relax ()
          done))
    in
    let domain = Domain.spawn work in
    work ();
    Domain.join domain;
    match Sys.signal Sys.sigterm Sys.Signal_default with
    | Sys.Signal_default -> ()
    | _ ->
      leaked := true;
      Printf.eprintf "round %d: the SIGTERM handler survived both switches\n%!" !round
  done;
  if !leaked then exit 1 else exit 0
;;

let test_concurrent_registration_restores_disposition () =
  let pid =
    Unix.create_process
      Sys.executable_name
      [| Sys.executable_name; "--concurrent-registration-child" |]
      Unix.stdin
      Unix.stdout
      Unix.stderr
  in
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED 0 -> ()
  | _, Unix.WEXITED n ->
    Windtrap.failf
      "child exited %d; a SIGTERM handler was left installed after both runtimes closed"
      n
  | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> Windtrap.fail "child ended unexpectedly"
;;

let double_signal_child () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let _promise, resolver = Eio.Promise.create () in
  Sol_runtime.install_signal_handler ~sw resolver;
  Unix.kill (Unix.getpid ()) Sys.sigterm;
  Eio.Time.sleep env#clock 0.2;
  Unix.kill (Unix.getpid ()) Sys.sigterm;
  Eio.Time.sleep env#clock 5.0;
  exit 3
;;

let test_second_signal_terminates () =
  let pid =
    Unix.create_process
      Sys.executable_name
      [| Sys.executable_name; "--double-signal-child" |]
      Unix.stdin
      Unix.stdout
      Unix.stderr
  in
  match Unix.waitpid [] pid with
  | _, Unix.WSIGNALED s when s = Sys.sigterm -> ()
  | _, Unix.WEXITED n ->
    Windtrap.failf "child exited %d; the second SIGTERM was swallowed" n
  | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> Windtrap.fail "child ended unexpectedly"
;;

let () =
  if Array.length Sys.argv > 1
  then (
    match Sys.argv.(1) with
    | "--double-signal-child" -> double_signal_child ()
    | "--concurrent-registration-child" -> concurrent_registration_child ()
    | _ -> ());
  Windtrap.run
    "sol_runtime"
    [ Windtrap.group
        "install_signal_handler"
        [ Windtrap.test "SIGTERM resolves the stop promise" test_sigterm_resolves_promise
        ; Windtrap.test "SIGINT resolves the stop promise" test_sigint_resolves_promise
        ; Windtrap.test
            "one signal reaches every registration"
            test_one_signal_reaches_every_registration
        ; Windtrap.test
            "disposition restored after the switch ends"
            test_disposition_restored_after_the_switch_ends
        ; Windtrap.test
            "concurrent registration restores the original disposition (BUG-074)"
            test_concurrent_registration_restores_disposition
        ; Windtrap.test "a second signal terminates" test_second_signal_terminates
        ]
    ]
;;
