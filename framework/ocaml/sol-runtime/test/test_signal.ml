(* REFAC-081: assert shutdown *behaviour*, not the helper's internals. Once the
   handler is installed, a real signal must resolve the promise a consumer
   awaits — that is the contract the three primitives depend on. *)

let await_resolved env promise =
  (* Raises Eio.Time.Timeout if the handler's byte never reaches the pipe, so a
     broken implementation fails the test instead of hanging it. *)
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

(* BUG-047: a process hosting several primitives (the local demo runs svc, worker
   and jobs together) must deliver one SIGTERM to every one of them. With a
   handler per install, the last one installed won. *)
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

(* Once no primitive is running, SIGTERM means what it meant before: the handler
   (and its pipes, now closed) must not linger. *)
let test_disposition_restored_after_the_switch_ends () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let _promise, resolver = Eio.Promise.create () in
      Sol_runtime.install_signal_handler ~sw resolver));
  let now = Sys.signal Sys.sigterm Sys.Signal_default in
  Alcotest.(check bool)
    "SIGTERM is back to the default disposition"
    true
    (now = Sys.Signal_default)
;;

(* A second signal while the first is being handled terminates the process. Run
   in a child: success means the child is killed by SIGTERM. *)
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
    Alcotest.failf "child exited %d; the second SIGTERM was swallowed" n
  | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> Alcotest.fail "child ended unexpectedly"
;;

let () =
  if Array.length Sys.argv > 1 && Sys.argv.(1) = "--double-signal-child"
  then double_signal_child ();
  Alcotest.run
    "sol_runtime"
    [ ( "install_signal_handler"
      , [ Alcotest.test_case
            "SIGTERM resolves the stop promise"
            `Quick
            test_sigterm_resolves_promise
        ; Alcotest.test_case
            "SIGINT resolves the stop promise"
            `Quick
            test_sigint_resolves_promise
        ; Alcotest.test_case
            "one signal reaches every registration"
            `Quick
            test_one_signal_reaches_every_registration
        ; Alcotest.test_case
            "disposition restored after the switch ends"
            `Quick
            test_disposition_restored_after_the_switch_ends
        ; Alcotest.test_case
            "a second signal terminates"
            `Quick
            test_second_signal_terminates
        ] )
    ]
;;
