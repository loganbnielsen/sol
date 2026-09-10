let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () -> Unix.putenv name (Option.value old ~default:""))
;;

let header name headers = List.assoc_opt name headers

let test_env_var () =
  Alcotest.(check string)
    "normalizes service source name"
    "CHECKOUT_SVC_URL"
    (Peer.env_var "checkout_svc")
;;

let test_url () =
  with_env "CHECKOUT_SVC_URL" "http://checkout.pluto.svc.cluster.local" (fun () ->
    match Peer.url "checkout_svc" with
    | Ok uri ->
      Alcotest.(check string)
        "url"
        "http://checkout.pluto.svc.cluster.local"
        (Uri.to_string uri)
    | Error err -> Alcotest.fail (Peer.error_to_string err))
;;

let test_relative_url_fails () =
  with_env "CHECKOUT_SVC_URL" "localhost:8081" (fun () ->
    match Peer.url "checkout_svc" with
    | Error (`Config msg) ->
      Alcotest.(check string)
        "config error"
        "CHECKOUT_SVC_URL must be an absolute http(s) URL"
        msg
    | Ok uri -> Alcotest.fail ("expected config error, got " ^ Uri.to_string uri))
;;

let test_headers_from_span env () =
  with_env "SOL_API_KEY_FILE" "" (fun () ->
    with_env "SOL_API_KEY" "secret" (fun () ->
      let obs =
        Sol_obs.of_env
          ~net:env#net
          ~clock:env#clock
          ~mono_clock:env#mono_clock
          ~service:"test-svc"
          ()
      in
      Sol_obs.with_span obs "caller" (fun span ->
        let trace_ctx = Sol_obs.current_trace_context span in
        match Peer.headers ~env ~trace_ctx ~peer:"checkout_svc" () with
        | Error err -> Alcotest.fail (Peer.error_to_string err)
        | Ok headers ->
          Alcotest.(check (option string))
            "api key"
            (Some "secret")
            (header "x-api-key" headers);
          Alcotest.(check (option string))
            "traceparent"
            (Some (Obs_trace.to_traceparent trace_ctx))
            (header "traceparent" headers))))
;;

let test_file_precedes_env env () =
  let path = Filename.temp_file "sol-peer-key" ".txt" in
  let oc = open_out path in
  output_string oc "from-file\n";
  close_out oc;
  Fun.protect
    (fun () ->
       with_env "SOL_API_KEY_FILE" path (fun () ->
         with_env "SOL_API_KEY" "from-env" (fun () ->
           match Peer.headers ~env ~peer:"checkout_svc" () with
           | Error err -> Alcotest.fail (Peer.error_to_string err)
           | Ok headers ->
             Alcotest.(check (option string))
               "file api key"
               (Some "from-file")
               (header "x-api-key" headers))))
    ~finally:(fun () -> Sys.remove path)
;;

let () =
  Eio_main.run
  @@ fun env ->
  Alcotest.run
    "sol-svc peer"
    [ ( "peer"
      , [ Alcotest.test_case "env var" `Quick test_env_var
        ; Alcotest.test_case "url" `Quick test_url
        ; Alcotest.test_case "relative url fails" `Quick test_relative_url_fails
        ; Alcotest.test_case
            "headers from current span"
            `Quick
            (test_headers_from_span env)
        ; Alcotest.test_case "api key file precedence" `Quick (test_file_precedes_env env)
        ] )
    ]
;;
