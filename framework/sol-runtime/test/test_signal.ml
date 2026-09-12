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

let () =
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
        ] )
    ]
;;
