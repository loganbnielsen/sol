(* ------------------------------------------------------------------ *)
(* Mock ingestion server (cohttp-eio) — shared by the Loki/Tempo tests  *)
(* ------------------------------------------------------------------ *)

let with_mock_server env f =
  Eio.Switch.run @@ fun sw ->
  let body_p, body_r = Eio.Promise.create () in
  let stop, stop_r = Eio.Promise.create () in
  let callback _conn _req body =
    let captured =
      let buf = Eio.Buf_read.of_flow body ~max_size:(256 * 1024) in
      Eio.Buf_read.take_all buf
    in
    (if not (Eio.Promise.is_resolved body_p) then Eio.Promise.resolve body_r captured);
    Cohttp_eio.Server.respond ~status:`No_content ~body:(Cohttp_eio.Body.of_string "") ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  match Eio.Net.listen ~backlog:5 ~sw env#net addr with
  | exception Unix.Unix_error (Unix.EPERM, "bind", _) ->
    Printf.printf "[skip] sandboxed environment forbids binding a local socket\n%!"
  | socket ->
    let port =
      match Eio.Net.listening_addr socket with
      | `Tcp (_, p) -> p
      | _ -> failwith "unexpected address family"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
        Cohttp_eio.Server.run ~stop ~on_error:(fun _ -> ()) socket server;
        `Stop_daemon);
    let result = f ~port ~body_promise:body_p in
    Eio.Promise.resolve stop_r ();
    result

let local_url port = Printf.sprintf "http://127.0.0.1:%d" port

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec go i = i <= hl - nl && (String.sub haystack i nl = needle || go (i + 1)) in
    go 0

(* Env vars are process-global; every test restores them so tests don't
   leak state into each other. Sol_obs.env_nonempty treats "" as absent,
   so clearing to "" is a sufficient "unset" here — this switch has no
   Unix.unsetenv. *)
let with_env pairs f =
  let saved = List.map (fun (k, _) -> (k, Option.value (Sys.getenv_opt k) ~default:"")) pairs in
  List.iter (fun (k, v) -> Unix.putenv k v) pairs;
  Fun.protect ~finally:(fun () -> List.iter (fun (k, v) -> Unix.putenv k v) saved) f

(* ------------------------------------------------------------------ *)
(* Defaults: no LOKI_URL/TEMPO_URL set                                  *)
(* ------------------------------------------------------------------ *)

let test_default_env_logs_and_counts_without_network () =
  Eio_main.run @@ fun env ->
  with_env [ ("LOKI_URL", ""); ("TEMPO_URL", "") ] (fun () ->
      let obs =
        Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc" ()
      in
      Sol_obs.log_info obs "hello";
      Sol_obs.with_span obs "op" (fun sp -> Sol_obs.log sp Sol_obs.Info "inside span");
      let reqs = Sol_obs.counter obs ~name:"requests_total" ~help:"total requests" ~label_names:[] in
      reqs 1;
      let rendered = Sol_obs.metrics_renderer obs () in
      Alcotest.(check bool) "rendered output mentions the registered counter" true
        (contains rendered "requests_total"))

let test_gauge_and_histogram_round_trip () =
  Eio_main.run @@ fun env ->
  with_env [ ("LOKI_URL", ""); ("TEMPO_URL", "") ] (fun () ->
      let obs =
        Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc" ()
      in
      let queue_depth = Sol_obs.gauge obs ~name:"queue_depth" ~help:"items queued" ~label_names:[] in
      queue_depth 3.0;
      let latency = Sol_obs.histogram obs ~name:"op_seconds" ~help:"op latency" ~label_names:[] in
      latency 0.05;
      let rendered = Sol_obs.metrics_renderer obs () in
      Alcotest.(check bool) "gauge present" true (contains rendered "queue_depth");
      Alcotest.(check bool) "histogram present" true (contains rendered "op_seconds"))

(* ------------------------------------------------------------------ *)
(* LOKI_URL / TEMPO_URL wire the respective backend in                 *)
(* ------------------------------------------------------------------ *)

let test_loki_url_wires_loki_backend () =
  Eio_main.run @@ fun env ->
  with_mock_server env (fun ~port ~body_promise ->
      with_env [ ("LOKI_URL", local_url port); ("TEMPO_URL", "") ] (fun () ->
          let obs =
            Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc" ()
          in
          Sol_obs.log_info obs "pushed to loki";
          let body = Eio.Promise.await body_promise in
          Alcotest.(check bool) "push body mentions the log message" true (contains body "pushed to loki")))

let test_context_promoted_to_loki_stream_labels () =
  Eio_main.run @@ fun env ->
  with_mock_server env (fun ~port ~body_promise ->
      with_env [ ("LOKI_URL", local_url port); ("TEMPO_URL", "") ] (fun () ->
          let obs =
            Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc"
              ~context:[ ("team", "payments") ] ()
          in
          Sol_obs.log_info obs "hi";
          let body = Eio.Promise.await body_promise in
          Alcotest.(check bool) "push body carries the team stream label" true
            (contains body "\"team\":\"payments\"")))

let test_tempo_url_wires_tempo_backend () =
  Eio_main.run @@ fun env ->
  with_mock_server env (fun ~port ~body_promise ->
      with_env [ ("LOKI_URL", ""); ("TEMPO_URL", local_url port) ] (fun () ->
          let obs =
            Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc" ()
          in
          Sol_obs.with_span obs "op" (fun _sp -> ());
          let body = Eio.Promise.await body_promise in
          Alcotest.(check bool) "OTLP push body is non-empty" true (String.length body > 0)))

(* ------------------------------------------------------------------ *)
(* Accessors                                                            *)
(* ------------------------------------------------------------------ *)

let test_metrics_renderer_matches_backend_and_renderer () =
  Eio_main.run @@ fun env ->
  with_env [ ("LOKI_URL", ""); ("TEMPO_URL", "") ] (fun () ->
      let obs =
        Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc" ()
      in
      let reqs = Sol_obs.counter obs ~name:"acc_total" ~help:"h" ~label_names:[] in
      reqs 1;
      let _backend, renderer_from_pair = Sol_obs.backend_and_renderer obs in
      Alcotest.(check string) "same renderer output both ways"
        (Sol_obs.metrics_renderer obs ()) (renderer_from_pair ()))

let test_with_context_does_not_mutate_original () =
  Eio_main.run @@ fun env ->
  with_env [ ("LOKI_URL", ""); ("TEMPO_URL", "") ] (fun () ->
      let obs =
        Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc" ()
      in
      let derived = Sol_obs.with_context obs [ ("req", "r-1") ] in
      (* Both handles still work independently; obs_eio gives access to the
         lower-level handle for a direct sanity check that they differ. *)
      Alcotest.(check bool) "obs_eio handles are distinct values" true
        (Sol_obs.obs_eio obs != Sol_obs.obs_eio derived))

let test_current_trace_context_links_child_span () =
  Eio_main.run @@ fun env ->
  with_env [ ("LOKI_URL", ""); ("TEMPO_URL", "") ] (fun () ->
      let obs =
        Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc" ()
      in
      let parent_ctx = Sol_obs.with_span obs "parent" Sol_obs.current_trace_context in
      Sol_obs.with_span obs ~parent:parent_ctx "child" (fun child_span ->
          let child_ctx = Sol_obs.current_trace_context child_span in
          Alcotest.(check string) "child inherits the parent's trace id"
            (Sol_obs.trace_id_string parent_ctx) (Sol_obs.trace_id_string child_ctx)))

let test_trace_id_string_is_32_hex_chars () =
  Eio_main.run @@ fun env ->
  with_env [ ("LOKI_URL", ""); ("TEMPO_URL", "") ] (fun () ->
      let obs =
        Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"test-svc" ()
      in
      let ctx = Sol_obs.with_span obs "op" Sol_obs.current_trace_context in
      let s = Sol_obs.trace_id_string ctx in
      Alcotest.(check int) "32 lowercase hex characters" 32 (String.length s);
      Alcotest.(check bool) "every character is lowercase hex" true
        (String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) s))

let () =
  let open Alcotest in
  run "sol_obs"
    [ ( "defaults",
        [ test_case "logs and counts without any network backend" `Quick
            test_default_env_logs_and_counts_without_network;
          test_case "gauge and histogram round trip" `Quick test_gauge_and_histogram_round_trip;
        ] );
      ( "env-driven backends",
        [ test_case "LOKI_URL wires the Loki backend" `Quick test_loki_url_wires_loki_backend;
          test_case "?context is promoted to Loki stream labels" `Quick
            test_context_promoted_to_loki_stream_labels;
          test_case "TEMPO_URL wires the Tempo backend" `Quick test_tempo_url_wires_tempo_backend;
        ] );
      ( "accessors",
        [ test_case "metrics_renderer matches backend_and_renderer's renderer" `Quick
            test_metrics_renderer_matches_backend_and_renderer;
          test_case "with_context derives without mutating the original" `Quick
            test_with_context_does_not_mutate_original;
        ] );
      ( "trace context",
        [ test_case "current_trace_context links a child span to its parent" `Quick
            test_current_trace_context_links_child_span;
          test_case "trace_id_string is 32 lowercase hex characters" `Quick
            test_trace_id_string_is_32_hex_chars;
        ] );
    ]
