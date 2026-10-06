let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () -> Unix.putenv name (Option.value old ~default:""))
;;

let with_envs pairs f = List.fold_right (fun (k, v) acc () -> with_env k v acc) pairs f ()
let header name headers = List.assoc_opt name headers

let describe_headers headers =
  String.concat ", " (List.map (fun (k, v) -> k ^ "=" ^ v) headers)
;;

let checkout_svc =
  Peer.For_codegen.declared ~unit_id:"checkout/checkout_svc" ~service_name:"checkout_svc"
;;

let expect_ok = function
  | Ok headers -> headers
  | Error err -> Windtrap.fail (Peer.error_to_string err)
;;

let expect_config_error = function
  | Error (`Config msg) -> msg
  | Ok headers ->
    Windtrap.fail ("expected a config error, got " ^ describe_headers headers)
;;

let with_token_file contents f =
  let path = Filename.temp_file "sol-peer-token" ".txt" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  Fun.protect
    (fun () -> with_env "CHECKOUT_SVC_TOKEN_FILE" path f)
    ~finally:(fun () -> Sys.remove path)
;;

let test_env_var () =
  Windtrap.equal
    Windtrap.string
    ~msg:"normalizes service source name"
    "CHECKOUT_SVC_URL"
    (Peer.env_var "checkout_svc")
;;

let test_token_file_env_var () =
  Windtrap.equal
    Windtrap.string
    ~msg:"token file env var mirrors the url env var"
    "CHECKOUT_SVC_TOKEN_FILE"
    (Peer.token_file_env_var "checkout_svc")
;;

let test_url () =
  with_env "CHECKOUT_SVC_URL" "http://checkout.pluto.svc.cluster.local" (fun () ->
    match Peer.url checkout_svc with
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
    match Peer.url checkout_svc with
    | Error (`Config msg) ->
      Windtrap.equal
        Windtrap.string
        ~msg:"config error"
        "CHECKOUT_SVC_URL must be an absolute http(s) URL"
        msg
    | Ok uri -> Windtrap.fail ("expected config error, got " ^ Uri.to_string uri))
;;

(* The projection wins even when the shared key and the local opt-in are both
   present: a declared call authenticates by identity. *)
let test_projected_token_is_bearer env () =
  with_envs
    [ "SOL_API_KEY", "shared"; "SOL_ALLOW_PLAINTEXT_PEER_AUTH", "1" ]
    (fun () ->
       with_token_file "projected-token\n" (fun () ->
         let headers = expect_ok (Peer.headers ~env ~peer:checkout_svc ()) in
         Windtrap.equal
           (Windtrap.option Windtrap.string)
           ~msg:"bearer token"
           (Some "Bearer projected-token")
           (header "authorization" headers);
         Windtrap.equal
           (Windtrap.option Windtrap.string)
           ~msg:"the shared key is not also attached"
           None
           (header "x-api-key" headers)))
;;

(* A declared projection that cannot be read is a failure, not an absence: the
   caller must not fall back to the shared key. *)
let test_unreadable_projection_fails_closed env () =
  with_envs
    [ "SOL_API_KEY", "shared"
    ; "SOL_ALLOW_PLAINTEXT_PEER_AUTH", "1"
    ; "CHECKOUT_SVC_TOKEN_FILE", "/nonexistent/sol/projected/token"
    ]
    (fun () ->
       let msg = expect_config_error (Peer.headers ~env ~peer:checkout_svc ()) in
       Windtrap.equal
         Windtrap.bool
         ~msg:"names the unreadable projection"
         true
         (Sol_runtime.contains_substring ~needle:"CHECKOUT_SVC_TOKEN_FILE" msg))
;;

let test_empty_projection_fails_closed env () =
  with_envs
    [ "SOL_API_KEY", "shared"; "SOL_ALLOW_PLAINTEXT_PEER_AUTH", "1" ]
    (fun () ->
       with_token_file "" (fun () ->
         let msg = expect_config_error (Peer.headers ~env ~peer:checkout_svc ()) in
         Windtrap.equal
           Windtrap.bool
           ~msg:"an empty projection is named"
           true
           (Sol_runtime.contains_substring ~needle:"empty" msg)))
;;

(* Missing projection with no deliberate opt-in: fail closed, and never pick up
   SOL_API_KEY merely because the token is absent. *)
let test_missing_projection_without_opt_in_fails_closed env () =
  with_envs
    [ "SOL_API_KEY", "shared"
    ; "SOL_ALLOW_PLAINTEXT_PEER_AUTH", ""
    ; "CHECKOUT_SVC_TOKEN_FILE", ""
    ]
    (fun () ->
       let msg = expect_config_error (Peer.headers ~env ~peer:checkout_svc ()) in
       Windtrap.equal
         Windtrap.bool
         ~msg:"points at the development opt-in"
         true
         (Sol_runtime.contains_substring ~needle:Peer.plaintext_auth_opt_in msg))
;;

let test_opt_in_uses_shared_key env () =
  with_envs
    [ "SOL_API_KEY", "shared"
    ; "SOL_API_KEY_FILE", ""
    ; "SOL_ALLOW_PLAINTEXT_PEER_AUTH", "1"
    ; "CHECKOUT_SVC_TOKEN_FILE", ""
    ]
    (fun () ->
       let headers = expect_ok (Peer.headers ~env ~peer:checkout_svc ()) in
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:"shared key"
         (Some "shared")
         (header "x-api-key" headers);
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:"no bearer without a projection"
         None
         (header "authorization" headers))
;;

let test_opt_in_still_needs_a_credential env () =
  with_envs
    [ "SOL_API_KEY", ""
    ; "SOL_API_KEY_FILE", ""
    ; "SOL_ALLOW_PLAINTEXT_PEER_AUTH", "1"
    ; "CHECKOUT_SVC_TOKEN_FILE", ""
    ]
    (fun () -> ignore (expect_config_error (Peer.headers ~env ~peer:checkout_svc ())))
;;

let test_file_precedes_env env () =
  let path = Filename.temp_file "sol-peer-key" ".txt" in
  let oc = open_out path in
  output_string oc "from-file\n";
  close_out oc;
  Fun.protect
    (fun () ->
       with_envs
         [ "SOL_ALLOW_PLAINTEXT_PEER_AUTH", "1"; "CHECKOUT_SVC_TOKEN_FILE", "" ]
         (fun () ->
            with_env "SOL_API_KEY_FILE" path (fun () ->
              with_env "SOL_API_KEY" "from-env" (fun () ->
                let headers = expect_ok (Peer.headers ~env ~peer:checkout_svc ()) in
                Windtrap.equal
                  (Windtrap.option Windtrap.string)
                  ~msg:"file api key"
                  (Some "from-file")
                  (header "x-api-key" headers)))))
    ~finally:(fun () -> Sys.remove path)
;;

let test_traceparent_with_projection env () =
  with_env "SOL_API_KEY" "" (fun () ->
    with_token_file "projected-token" (fun () ->
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
        let headers = expect_ok (Peer.headers ~env ~peer:checkout_svc ~trace_ctx ()) in
        Windtrap.equal
          (Windtrap.option Windtrap.string)
          ~msg:"traceparent"
          (Some (Obs_trace.to_traceparent trace_ctx))
          (header "traceparent" headers))))
;;

let () =
  Eio_main.run
  @@ fun env ->
  Windtrap.run
    "sol-svc peer"
    [ Windtrap.group
        "peer"
        [ Windtrap.test "env var" test_env_var
        ; Windtrap.test "token file env var" test_token_file_env_var
        ; Windtrap.test "url" test_url
        ; Windtrap.test "relative url fails" test_relative_url_fails
        ; Windtrap.test
            "projected token is sent as bearer"
            (test_projected_token_is_bearer env)
        ; Windtrap.test
            "unreadable projection fails closed"
            (test_unreadable_projection_fails_closed env)
        ; Windtrap.test
            "empty projection fails closed"
            (test_empty_projection_fails_closed env)
        ; Windtrap.test
            "missing projection without opt-in fails closed"
            (test_missing_projection_without_opt_in_fails_closed env)
        ; Windtrap.test
            "explicit local opt-in uses the shared key"
            (test_opt_in_uses_shared_key env)
        ; Windtrap.test
            "the local opt-in still needs a credential"
            (test_opt_in_still_needs_a_credential env)
        ; Windtrap.test "api key file precedence" (test_file_precedes_env env)
        ; Windtrap.test
            "traceparent with projection"
            (test_traceparent_with_projection env)
        ]
    ]
;;
