module Ok_fn = struct
  let trigger = Fn.Cron
  let run () = Ok ()
end

module Err_fn = struct
  let trigger = Fn.Cron
  let run () = Error "something went wrong"
end

module Exn_fn = struct
  let trigger = Fn.Cron
  let run () = raise (Failure "boom")
end

module Lambda_fn = struct
  let trigger = Fn.Lambda
  let run () = Ok ()
end

module Should_not_run_fn = struct
  let trigger = Fn.Cron
  let run () = Windtrap.fail "stopped cron should not run"
end

let test_run_ok () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Ok_fn) in
  Windtrap.equal Windtrap.bool ~msg:"returns Ok" true (M.run ~env () = Ok ())
;;

let test_run_error () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Err_fn) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"returns run error"
    true
    (M.run ~env () = Error (`Run "something went wrong"))
;;

let test_run_exception () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Exn_fn) in
  match M.run ~env () with
  | Error (`Run msg) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"exception captured"
      true
      (Sol_runtime.contains_substring ~needle:"boom" msg)
  | _ -> Windtrap.fail "expected run error"
;;

let test_external_stop_before_cron_run () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Should_not_run_fn) in
  let stop, stop_r = Eio.Promise.create () in
  Eio.Promise.resolve stop_r ();
  Windtrap.equal
    Windtrap.bool
    ~msg:"returns signalled"
    true
    (M.run ~env ~stop () = Error `Signalled)
;;

let test_metrics_ok_counter () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let module M = Fn.Make (Ok_fn) in
  let obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"test-fn"
      ()
  in
  let renderer = Sol_obs.metrics_renderer obs in
  Windtrap.equal Windtrap.bool ~msg:"returns Ok" true (M.run ~env ~ot:obs () = Ok ());
  let output = renderer () in
  Windtrap.equal
    Windtrap.bool
    ~msg:"counter family present"
    true
    (Sol_runtime.contains_substring ~needle:"sol_fn_invocations_total" output);
  Windtrap.equal
    Windtrap.bool
    ~msg:"status=ok label present"
    true
    (Sol_runtime.contains_substring ~needle:{|status="ok"|} output)
;;

let test_metrics_error_counter () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let module M = Fn.Make (Err_fn) in
  let obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"test-fn"
      ()
  in
  let renderer = Sol_obs.metrics_renderer obs in
  ignore (M.run ~env ~ot:obs ());
  let output = renderer () in
  Windtrap.equal
    Windtrap.bool
    ~msg:"status=error label present"
    true
    (Sol_runtime.contains_substring ~needle:{|status="error"|} output)
;;

let test_metrics_duration () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let module M = Fn.Make (Ok_fn) in
  let obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"test-fn"
      ()
  in
  let renderer = Sol_obs.metrics_renderer obs in
  Windtrap.equal Windtrap.bool ~msg:"returns Ok" true (M.run ~env ~ot:obs () = Ok ());
  let output = renderer () in
  Windtrap.equal
    Windtrap.bool
    ~msg:"duration histogram present"
    true
    (Sol_runtime.contains_substring ~needle:"sol_fn_duration_seconds" output)
;;

let test_push_error_no_raise () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Ok_fn) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"returns Ok"
    true
    (M.run ~env ~pushgateway_url:"http://127.0.0.1:1" () = Ok ())
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () -> Unix.putenv name (Option.value old ~default:""))
;;

let test_push_uses_env_url_and_workload_job () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let socket =
    Eio.Net.listen
      ~sw
      ~backlog:4
      ~reuse_addr:true
      env#net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Windtrap.fail "no port"
  in
  let request_line, request_line_r = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Net.accept_fork ~sw socket ~on_error:raise (fun flow _ ->
      let buf = Eio.Buf_read.of_flow flow ~max_size:65536 in
      ignore (Eio.Promise.try_resolve request_line_r (Eio.Buf_read.line buf));
      Eio.Flow.copy_string
        "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        flow);
    `Stop_daemon);
  with_env "PUSHGATEWAY_URL" (Printf.sprintf "http://127.0.0.1:%d" port) (fun () ->
    with_env "SOL_PUSHGATEWAY_JOB" "myapp-billing.invoice-fn" (fun () ->
      let module M = Fn.Make (Ok_fn) in
      Windtrap.equal Windtrap.bool ~msg:"run returns Ok" true (M.run ~env () = Ok ())));
  let line =
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () -> Eio.Promise.await request_line)
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:(Printf.sprintf "pushed to the workload's own group (%S)" line)
    true
    (Sol_runtime.contains_substring ~needle:"/metrics/job/myapp-billing.invoice-fn" line)
;;

let test_lambda_trigger_requires_runtime_api () =
  match Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" with
  | Some _ ->
    Windtrap.fail
      "AWS_LAMBDA_RUNTIME_API is set, so this case cannot establish that a Lambda \
       trigger fails closed without it; unset the variable for this run"
  | None ->
    Eio_main.run
    @@ fun env ->
    let module M = Fn.Make (Lambda_fn) in
    (match M.run ~env () with
     | Error (`Config msg) ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"reports missing runtime api"
         true
         (Sol_runtime.contains_substring ~needle:"AWS_LAMBDA_RUNTIME_API is not set" msg)
     | _ -> Windtrap.fail "expected config error")
;;

let () =
  Windtrap.run
    "sol-fn"
    [ Windtrap.group
        "lifecycle"
        [ Windtrap.test "run_ok" test_run_ok
        ; Windtrap.test "run_error" test_run_error
        ; Windtrap.test "run_exception" test_run_exception
        ; Windtrap.test "external stop before cron run" test_external_stop_before_cron_run
        ]
    ; Windtrap.group
        "metrics"
        [ Windtrap.test "metrics_ok_counter" test_metrics_ok_counter
        ; Windtrap.test "metrics_error_counter" test_metrics_error_counter
        ; Windtrap.test "metrics_duration" test_metrics_duration
        ]
    ; Windtrap.group
        "push"
        [ Windtrap.test "push_error_no_raise" test_push_error_no_raise
        ; Windtrap.test
            "push uses PUSHGATEWAY_URL and SOL_PUSHGATEWAY_JOB"
            test_push_uses_env_url_and_workload_job
        ]
    ; Windtrap.group
        "lambda"
        [ Windtrap.test
            "requires AWS_LAMBDA_RUNTIME_API"
            test_lambda_trigger_requires_runtime_api
        ]
    ]
;;
