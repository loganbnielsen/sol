let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () -> Unix.putenv name (Option.value old ~default:""))
;;

let header name headers = List.assoc_opt name headers

let test_env_var () =
  Windtrap.equal
    Windtrap.string
    ~msg:"normalizes service source name"
    "CHECKOUT_SVC_URL"
    (Peer.env_var "checkout_svc")
;;

let test_url () =
  with_env "CHECKOUT_SVC_URL" "http://checkout.pluto.svc.cluster.local" (fun () ->
    match Peer.url "checkout_svc" with
    | Ok uri ->
      Windtrap.equal
        Windtrap.string
        ~msg:"url"
        "http://checkout.pluto.svc.cluster.local"
        (Uri.to_string uri)
    | Error err -> Windtrap.fail (Peer.error_to_string err))
;;

let test_relative_url_fails () =
  with_env "CHECKOUT_SVC_URL" "localhost:8081" (fun () ->
    match Peer.url "checkout_svc" with
    | Error (`Config msg) ->
      Windtrap.equal
        Windtrap.string
        ~msg:"config error"
        "CHECKOUT_SVC_URL must be an absolute http(s) URL"
        msg
    | Ok uri -> Windtrap.fail ("expected config error, got " ^ Uri.to_string uri))
;;

let test_headers_from_span env () =
  with_env "SOL_API_KEY_FILE" "" (fun () ->
    with_env "SOL_API_KEY" "secret" (fun () ->
      Eio.Switch.run
      @@ fun sw ->
      let obs =
        Sol_obs.of_env
          ~sw
          ~net:env#net
          ~clock:env#clock
          ~mono_clock:env#mono_clock
          ~service:"test-svc"
          ()
      in
      Sol_obs.with_span obs "caller" (fun span ->
        let trace_ctx = Sol_obs.current_trace_context span in
        match Peer.headers ~env ~trace_ctx () with
        | Error err -> Windtrap.fail (Peer.error_to_string err)
        | Ok headers ->
          Windtrap.equal
            (Windtrap.option Windtrap.string)
            ~msg:"api key"
            (Some "secret")
            (header "x-api-key" headers);
          Windtrap.equal
            (Windtrap.option Windtrap.string)
            ~msg:"traceparent"
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
           match Peer.headers ~env () with
           | Error err -> Windtrap.fail (Peer.error_to_string err)
           | Ok headers ->
             Windtrap.equal
               (Windtrap.option Windtrap.string)
               ~msg:"file api key"
               (Some "from-file")
               (header "x-api-key" headers))))
    ~finally:(fun () -> Sys.remove path)
;;

let () =
  Eio_main.run
  @@ fun env ->
  Windtrap.run
    "sol-svc peer"
    [ Windtrap.group
        "peer"
        [ Windtrap.test "env var" test_env_var
        ; Windtrap.test "url" test_url
        ; Windtrap.test "relative url fails" test_relative_url_fails
        ; Windtrap.test "headers from current span" (test_headers_from_span env)
        ; Windtrap.test "api key file precedence" (test_file_precedes_env env)
        ]
    ]
;;
