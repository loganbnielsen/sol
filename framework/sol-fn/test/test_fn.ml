(* ── Fixtures ───────────────────────────────────────────────────────────── *)

module Ok_fn = struct
  let trigger = Fn.Cron "0 * * * *"
  let run () = Ok ()
end

module Err_fn = struct
  let trigger = Fn.Cron "0 * * * *"
  let run () = Error "something went wrong"
end

module Exn_fn = struct
  let trigger = Fn.Cron "0 * * * *"
  let run () = raise (Failure "boom")
end

module Lambda_fn = struct
  let trigger = Fn.Lambda
  let run () = Ok ()
end

module Should_not_run_fn = struct
  let trigger = Fn.Cron "* * * * *"
  let run () = Alcotest.fail "stopped cron should not run"
end

let contains needle haystack =
  let nl = String.length needle
  and hl = String.length haystack in
  if nl = 0
  then true
  else if nl > hl
  then false
  else (
    let found = ref false in
    for i = 0 to hl - nl do
      if not !found
      then (
        let rec eq j =
          j >= nl
          || (String.unsafe_get haystack (i + j) = String.unsafe_get needle j && eq (j + 1)
             )
        in
        if eq 0 then found := true)
    done;
    !found)
;;

(* ── Test: run_ok ───────────────────────────────────────────────────────── *)

let test_run_ok () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Ok_fn) in
  Alcotest.(check bool) "returns Ok" true (M.run ~env () = Ok ())
;;

(* ── Test: run_error ────────────────────────────────────────────────────── *)

let test_run_error () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Err_fn) in
  Alcotest.(check bool)
    "returns run error"
    true
    (M.run ~env () = Error (`Run "something went wrong"))
;;

(* ── Test: run_exception ────────────────────────────────────────────────── *)

let test_run_exception () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Exn_fn) in
  match M.run ~env () with
  | Error (`Run msg) ->
    Alcotest.(check bool) "exception captured" true (contains "boom" msg)
  | _ -> Alcotest.fail "expected run error"
;;

let test_external_stop_before_cron_run () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Should_not_run_fn) in
  let stop, stop_r = Eio.Promise.create () in
  Eio.Promise.resolve stop_r ();
  Alcotest.(check bool) "returns signalled" true (M.run ~env ~stop () = Error `Signalled)
;;

(* ── Test: metrics_ok_counter ───────────────────────────────────────────── *)

let test_metrics_ok_counter () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Ok_fn) in
  let obs =
    Sol_obs.of_env
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"test-fn"
      ()
  in
  let renderer = Sol_obs.metrics_renderer obs in
  Alcotest.(check bool) "returns Ok" true (M.run ~env ~ot:obs () = Ok ());
  let output = renderer () in
  Alcotest.(check bool)
    "counter family present"
    true
    (contains "sol_fn_invocations_total" output);
  Alcotest.(check bool) "status=ok label present" true (contains {|status="ok"|} output)
;;

(* ── Test: metrics_error_counter ────────────────────────────────────────── *)

let test_metrics_error_counter () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Err_fn) in
  let obs =
    Sol_obs.of_env
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"test-fn"
      ()
  in
  let renderer = Sol_obs.metrics_renderer obs in
  ignore (M.run ~env ~ot:obs ());
  let output = renderer () in
  Alcotest.(check bool)
    "status=error label present"
    true
    (contains {|status="error"|} output)
;;

(* ── Test: metrics_duration ─────────────────────────────────────────────── *)

let test_metrics_duration () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Ok_fn) in
  let obs =
    Sol_obs.of_env
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"test-fn"
      ()
  in
  let renderer = Sol_obs.metrics_renderer obs in
  Alcotest.(check bool) "returns Ok" true (M.run ~env ~ot:obs () = Ok ());
  let output = renderer () in
  Alcotest.(check bool)
    "duration histogram present"
    true
    (contains "sol_fn_duration_seconds" output)
;;

(* ── Test: push_error_no_raise ──────────────────────────────────────────── *)

(* Port 1 refuses connections — push_metrics must swallow the error and
   still return normally (or raise Failure for error runs, never hang). *)
let test_push_error_no_raise () =
  Eio_main.run
  @@ fun env ->
  let module M = Fn.Make (Ok_fn) in
  Alcotest.(check bool)
    "returns Ok"
    true
    (M.run ~env ~pushgateway_url:"http://127.0.0.1:1" () = Ok ())
;;

(* ── Test: lambda_trigger_requires_runtime_api ──────────────────────────── *)

(* Lambda_runtime.run_loop itself is tested in lambda-eio; here we only verify
   sol-fn's marginal surface — read AWS_LAMBDA_RUNTIME_API and fail fast when
   unset — since re-testing the loop would mean racy real OS signals. *)
(* Assumes AWS_LAMBDA_RUNTIME_API is unset, as on any normal dev/CI machine.
   OCaml's Unix has no unsetenv to force-clear it, so skip if it's somehow set. *)
let test_lambda_trigger_requires_runtime_api () =
  if Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" <> None
  then
    Printf.printf
      "[skip] AWS_LAMBDA_RUNTIME_API is set in this environment — skipping\n%!"
  else
    Eio_main.run
    @@ fun env ->
    let module M = Fn.Make (Lambda_fn) in
    match M.run ~env () with
    | Error (`Config msg) ->
      Alcotest.(check bool)
        "reports missing runtime api"
        true
        (contains "AWS_LAMBDA_RUNTIME_API is not set" msg)
    | _ -> Alcotest.fail "expected config error"
;;

(* ── Runner ─────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "sol-fn"
    [ ( "lifecycle"
      , [ Alcotest.test_case "run_ok" `Quick test_run_ok
        ; Alcotest.test_case "run_error" `Quick test_run_error
        ; Alcotest.test_case "run_exception" `Quick test_run_exception
        ; Alcotest.test_case
            "external stop before cron run"
            `Quick
            test_external_stop_before_cron_run
        ] )
    ; ( "metrics"
      , [ Alcotest.test_case "metrics_ok_counter" `Quick test_metrics_ok_counter
        ; Alcotest.test_case "metrics_error_counter" `Quick test_metrics_error_counter
        ; Alcotest.test_case "metrics_duration" `Quick test_metrics_duration
        ] )
    ; "push", [ Alcotest.test_case "push_error_no_raise" `Quick test_push_error_no_raise ]
    ; ( "lambda"
      , [ Alcotest.test_case
            "requires AWS_LAMBDA_RUNTIME_API"
            `Quick
            test_lambda_trigger_requires_runtime_api
        ] )
    ]
;;
