let () = Mirage_crypto_rng_unix.use_default ()
let workload_issuer = "https://kubernetes.default.svc"
let workload_audience = "checkout/checkout-svc"
let caller_service_account = "myapp-payments:charge-svc"
let caller_subject = "system:serviceaccount:" ^ caller_service_account
let caller_unit = "payments/charge-svc"
let rsa_priv_jwk = Jose.Jwk.make_priv_rsa (Mirage_crypto_pk.Rsa.generate ~bits:2048 ())
let rsa_jwks = Jose.Jwks.{ keys = [ Jose.Jwk.pub_of_priv rsa_priv_jwk ] }

(* A second issuer key, and the JWKS an issuer serves while both keys overlap
   during a rotation. *)
let rotated_priv_jwk =
  Jose.Jwk.make_priv_rsa (Mirage_crypto_pk.Rsa.generate ~bits:2048 ())
;;

let rotated_jwks =
  Jose.Jwks.
    { keys = [ Jose.Jwk.pub_of_priv rsa_priv_jwk; Jose.Jwk.pub_of_priv rotated_priv_jwk ]
    }
;;

(* The identity key `Auth_internal.get_jwks` caches workload-issuer keys under. *)
let workload_jwks_cache_key = "sol-workload-issuer:" ^ workload_issuer

let workload_identity ?(callers = [ caller_service_account, caller_unit ]) () =
  Auth.{ audience = workload_audience; callers; trusted_issuer = workload_issuer }
;;

let sign_workload
      ?(key = rsa_priv_jwk)
      ?(sub = caller_subject)
      ?(aud = workload_audience)
      ?(iss = workload_issuer)
      ?(exp_offset = 3600.0)
      ()
  =
  let payload =
    `Assoc
      [ "sub", `String sub
      ; "iss", `String iss
      ; "aud", `String aud
      ; "exp", `Int (int_of_float (Unix.gettimeofday () +. exp_offset))
      ]
  in
  match Jose.Jwt.sign ~payload key with
  | Ok token -> Jose.Jwt.to_string token
  | Error (`Msg message) -> failwith ("sign_workload: " ^ message)
;;

let headers token = Http.Header.of_list [ "authorization", "Bearer " ^ token ]

let with_env bindings f =
  let previous = List.map (fun (key, _) -> key, Sys.getenv_opt key) bindings in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (key, value) ->
           match value with
           | Some value -> Unix.putenv key value
           | None -> Unix.putenv key "")
        previous)
    (fun () ->
       List.iter (fun (key, value) -> Unix.putenv key value) bindings;
       f ())
;;

let test_service_reads_the_sol_projected_trust_and_call_policy () =
  with_env
    [ "SOL_UNIT", workload_audience
    ; "SOL_CALLED_BY", caller_unit ^ "=" ^ caller_service_account
    ; "SOL_TRUSTED_WORKLOAD_ISSUER", workload_issuer
    ]
    (fun () ->
       match
         Service.For_testing.workload_identity_config
           [ Route.get "/probe" (fun _ -> Response.ok "") ]
           `Public
       with
       | Error (`Config message) -> Windtrap.fail message
       | Ok None -> Windtrap.fail "an internal route did not request workload identity"
       | Ok (Some config) ->
         Windtrap.equal
           Windtrap.string
           ~msg:"projected audience"
           workload_audience
           config.audience;
         Windtrap.equal
           (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
           ~msg:"calls-derived caller set"
           [ caller_service_account, caller_unit ]
           config.callers;
         Windtrap.equal
           Windtrap.string
           ~msg:"target capability issuer projection"
           workload_issuer
           config.trusted_issuer)
;;

let test_internal_route_without_target_issuer_fails_startup () =
  with_env
    [ "SOL_UNIT", workload_audience
    ; "SOL_CALLED_BY", ""
    ; "SOL_TRUSTED_WORKLOAD_ISSUER", ""
    ]
    (fun () ->
       match
         Service.For_testing.workload_identity_config
           [ Route.get "/probe" (fun _ -> Response.ok "") ]
           `Public
       with
       | Error (`Config message) ->
         Windtrap.is_true
           ~msg:"startup failure names the missing target projection"
           (List.mem "SOL_TRUSTED_WORKLOAD_ISSUER" (String.split_on_char ' ' message))
       | Ok _ -> Windtrap.fail "an internal route started without a target-trusted issuer");
  with_env
    [ "SOL_UNIT", ""; "SOL_CALLED_BY", ""; "SOL_TRUSTED_WORKLOAD_ISSUER", "" ]
    (fun () ->
       match
         Service.For_testing.workload_identity_config
           [ Route.external_ (Route.get "/probe" (fun _ -> Response.ok "")) ]
           `Public
       with
       | Ok None -> ()
       | Error (`Config message) -> Windtrap.fail message
       | Ok (Some _) ->
         Windtrap.fail "an external-only service requested Sol workload identity")
;;

let dispatch
      ?(callers = [ caller_service_account, caller_unit ])
      ?(fetch_workload_jwks = fun _ -> Ok rsa_jwks)
      ?on_boundary
      headers
  =
  let handler req =
    match req.Request.auth with
    | Some { Auth.principal = Auth.Unit { unit; service_account }; _ } ->
      Response.json
        (Yojson.Safe.to_string
           (`Assoc [ "unit", `String unit; "service_account", `String service_account ]))
    | _ -> Response.internal_error "workload principal missing"
  in
  Service.For_testing.dispatch
    ~fetch_workload_jwks
    ~workload_identity:(workload_identity ~callers ())
    ?on_boundary
    ~routes:[ Route.get "/probe" handler ]
    (Http.Request.make ~meth:`GET ~headers "/probe")
    (Cohttp_eio.Body.of_string "")
;;

let test_declared_workload_authenticates_and_authorizes () =
  let boundary = ref None in
  let response =
    dispatch ~on_boundary:(fun b -> boundary := Some b) (headers (sign_workload ()))
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"internal request boundary"
    (Some "internal")
    (Option.map Observation.boundary_to_string !boundary);
  Windtrap.equal Windtrap.int ~msg:"status" 200 response.Response.status;
  let payload = Yojson.Safe.from_string response.Response.body in
  Windtrap.equal
    Windtrap.string
    ~msg:"caller unit"
    caller_unit
    (Yojson.Safe.Util.member "unit" payload |> Yojson.Safe.Util.to_string)
;;

let test_undeclared_caller_is_forbidden () =
  Windtrap.equal
    Windtrap.int
    ~msg:"authenticated caller outside graph → 403"
    403
    (dispatch ~callers:[] (headers (sign_workload ()))).Response.status
;;

let test_untrusted_issuer_is_unauthorized () =
  let fetched = ref false in
  let response =
    dispatch
      ~fetch_workload_jwks:(fun _ ->
        fetched := true;
        Ok rsa_jwks)
      (headers (sign_workload ~iss:"https://attacker.example" ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"issuer is not trusted → 401"
    401
    response.Response.status;
  Windtrap.is_false ~msg:"an untrusted issuer never reaches key resolution" !fetched
;;

let test_discovery_must_bind_keys_to_the_trusted_issuer () =
  let parse body =
    Service.For_testing.jwks_uri_of_discovery ~issuer:workload_issuer body
  in
  let good_uri = workload_issuer ^ "/keys" in
  let discovery issuer jwks_uri =
    Yojson.Safe.to_string
      (`Assoc [ "issuer", `String issuer; "jwks_uri", `String jwks_uri ])
  in
  (match parse (discovery workload_issuer good_uri) with
   | Ok uri -> Windtrap.equal Windtrap.string ~msg:"discovered JWKS URI" good_uri uri
   | Error error -> Windtrap.fail error);
  (match parse (discovery "https://attacker.example" good_uri) with
   | Error error ->
     Windtrap.is_true
       ~msg:"mismatched discovery issuer is rejected"
       (String.equal
          error
          "OIDC discovery issuer does not match the trusted target issuer")
   | Ok _ -> Windtrap.fail "a mismatched discovery issuer was accepted");
  (match parse (discovery workload_issuer "https://attacker.example/keys") with
   | Error error ->
     Windtrap.is_true
       ~msg:"cross-origin JWKS endpoint is rejected"
       (String.equal
          error
          "OIDC discovery jwks_uri must use the trusted issuer's HTTPS origin")
   | Ok _ -> Windtrap.fail "a cross-origin JWKS endpoint was accepted");
  match parse (discovery workload_issuer "http://kubernetes.default.svc/keys") with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "an insecure JWKS endpoint was accepted"
;;

let test_jwks_resolution_failure_fails_closed () =
  Service.For_testing.reset_jwks_cache ();
  let response =
    dispatch
      ~fetch_workload_jwks:(fun _ -> Error "issuer discovery unavailable")
      (headers (sign_workload ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"key resolution failure does not authenticate the request"
    500
    response.Response.status;
  Service.For_testing.reset_jwks_cache ()
;;

let test_wrong_audience_is_unauthorized () =
  Windtrap.equal
    Windtrap.int
    ~msg:"wrong audience → 401"
    401
    (dispatch (headers (sign_workload ~aud:"another/unit" ()))).Response.status
;;

let test_tampered_signature_is_unauthorized () =
  let token = sign_workload () in
  let parts = String.split_on_char '.' token in
  let tampered =
    match parts with
    | [ header; payload; signature ] ->
      let replacement = if signature.[0] = 'A' then 'B' else 'A' in
      String.concat
        "."
        [ header
        ; payload
        ; String.make 1 replacement ^ String.sub signature 1 (String.length signature - 1)
        ]
    | _ -> failwith "signed token should have three parts"
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"signature must verify → 401"
    401
    (dispatch (headers tampered)).Response.status
;;

let test_non_workload_subject_is_forbidden () =
  Windtrap.equal
    Windtrap.int
    ~msg:"verified user subject → 403"
    403
    (dispatch (headers (sign_workload ~sub:"customer-123" ()))).Response.status
;;

let test_missing_token_is_unauthorized () =
  Windtrap.equal
    Windtrap.int
    ~msg:"missing bearer → 401"
    401
    (dispatch (Http.Header.of_list [])).Response.status
;;

let test_jwks_cache_reuses_resolved_keys () =
  Service.For_testing.reset_jwks_cache ();
  let fetches = ref 0 in
  let fetch issuer =
    incr fetches;
    if issuer = workload_issuer then Ok rsa_jwks else Error "unexpected JWKS URL"
  in
  let token = headers (sign_workload ()) in
  let first = dispatch ~fetch_workload_jwks:fetch token in
  let second = dispatch ~fetch_workload_jwks:fetch token in
  Windtrap.equal Windtrap.int ~msg:"first request succeeds" 200 first.Response.status;
  Windtrap.equal Windtrap.int ~msg:"second request succeeds" 200 second.Response.status;
  Windtrap.equal Windtrap.int ~msg:"cached JWKS is reused" 1 !fetches;
  Service.For_testing.reset_jwks_cache ()
;;

(* A rotation: the cache holds only the old key and is younger than the 300s
   freshness window, so the primary lookup returns it; the token's unknown kid
   must trigger the unknown-kid refetch and pick up the overlapping new key. *)
let test_jwks_unknown_kid_refetches_a_rotation () =
  Service.For_testing.reset_jwks_cache ();
  Service.For_testing.seed_stale_jwks_cache
    ~url:workload_jwks_cache_key
    ~age_s:60.0
    ~jwks:(Jose.Jwks.to_string rsa_jwks);
  let fetches = ref 0 in
  let fetch issuer =
    incr fetches;
    if issuer = workload_issuer then Ok rotated_jwks else Error "unexpected JWKS URL"
  in
  let response =
    dispatch ~fetch_workload_jwks:fetch (headers (sign_workload ~key:rotated_priv_jwk ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"a token signed by the rotated key authenticates after the refetch"
    200
    response.Response.status;
  Windtrap.equal Windtrap.int ~msg:"the unknown kid caused exactly one refetch" 1 !fetches;
  Service.For_testing.reset_jwks_cache ()
;;

(* Kid-flood resistance: an unknown kid does not refetch a cache younger than
   the 30s unknown-kid interval, and the request stays refused rather than
   authenticating against a key that is not in the set. *)
let test_jwks_unknown_kid_refetch_is_debounced () =
  Service.For_testing.reset_jwks_cache ();
  Service.For_testing.seed_stale_jwks_cache
    ~url:workload_jwks_cache_key
    ~age_s:5.0
    ~jwks:(Jose.Jwks.to_string rsa_jwks);
  let fetches = ref 0 in
  let fetch issuer =
    incr fetches;
    if issuer = workload_issuer then Ok rotated_jwks else Error "unexpected JWKS URL"
  in
  let response =
    dispatch ~fetch_workload_jwks:fetch (headers (sign_workload ~key:rotated_priv_jwk ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"a fresh cache is not refetched on an unknown kid"
    0
    !fetches;
  Windtrap.equal
    Windtrap.int
    ~msg:"and the request is refused"
    401
    response.Response.status;
  Service.For_testing.reset_jwks_cache ()
;;

let test_external_route_bypasses_only_sol_workload_auth () =
  let boundary = ref None in
  let workload_principal = ref (Some ("unexpected", "principal")) in
  let response =
    Service.For_testing.dispatch
      ~on_boundary:(fun b -> boundary := Some b)
      ~on_workload_principal:(fun principal -> workload_principal := principal)
      ~routes:
        [ Route.external_
            (Route.get "/probe" (fun req ->
               match
                 req.Request.auth, Http.Header.get req.Request.headers "x-customer-token"
               with
               | Some _, _ -> Response.internal_error "Sol principal on external route"
               | None, None -> Response.unauthorized
               | None, Some "valid" -> Response.ok "application authenticated"
               | None, Some _ -> Response.unauthorized))
        ]
      (Http.Request.make ~meth:`GET "/probe")
      (Cohttp_eio.Body.of_string "")
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"external route can apply application-owned auth"
    401
    response.Response.status;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"external boundary is observed"
    (Some "external")
    (Option.map Observation.boundary_to_string !boundary);
  Windtrap.equal
    (Windtrap.option (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"external route has no Sol workload principal"
    None
    !workload_principal;
  let response =
    Service.For_testing.dispatch
      ~routes:
        [ Route.external_
            (Route.get "/probe" (fun req ->
               match
                 req.Request.auth, Http.Header.get req.Request.headers "x-customer-token"
               with
               | Some _, _ -> Response.internal_error "Sol principal on external route"
               | None, Some "valid" -> Response.ok "application authenticated"
               | _ -> Response.unauthorized))
        ]
      (Http.Request.make
         ~meth:`GET
         ~headers:(Http.Header.of_list [ "x-customer-token", "valid" ])
         "/probe")
      (Cohttp_eio.Body.of_string "")
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"application auth succeeds independently"
    200
    response.Response.status
;;

let () =
  Windtrap.run
    "sol-svc workload identity"
    [ Windtrap.test
        "service consumes the Sol-projected issuer and caller contract"
        test_service_reads_the_sol_projected_trust_and_call_policy
    ; Windtrap.test
        "internal routes fail closed without issuer; external-only routes do not require \
         it"
        test_internal_route_without_target_issuer_fails_startup
    ; Windtrap.test
        "declared caller authenticates and authorizes"
        test_declared_workload_authenticates_and_authorizes
    ; Windtrap.test "undeclared caller is forbidden" test_undeclared_caller_is_forbidden
    ; Windtrap.test
        "untrusted issuer is unauthorized"
        test_untrusted_issuer_is_unauthorized
    ; Windtrap.test
        "OIDC discovery and JWKS stay bound to the trusted issuer"
        test_discovery_must_bind_keys_to_the_trusted_issuer
    ; Windtrap.test
        "workload authentication fails closed when key resolution fails"
        test_jwks_resolution_failure_fails_closed
    ; Windtrap.test "wrong audience is unauthorized" test_wrong_audience_is_unauthorized
    ; Windtrap.test
        "tampered signature is unauthorized"
        test_tampered_signature_is_unauthorized
    ; Windtrap.test
        "non-workload subject is forbidden"
        test_non_workload_subject_is_forbidden
    ; Windtrap.test "missing token is unauthorized" test_missing_token_is_unauthorized
    ; Windtrap.test "JWKS cache reuses resolved keys" test_jwks_cache_reuses_resolved_keys
    ; Windtrap.test
        "an unknown kid refetches and picks up a rotated issuer key"
        test_jwks_unknown_kid_refetches_a_rotation
    ; Windtrap.test
        "an unknown kid does not refetch a cache younger than the refetch interval"
        test_jwks_unknown_kid_refetch_is_debounced
    ; Windtrap.test
        "external route bypasses only Sol workload auth"
        test_external_route_bypasses_only_sol_workload_auth
    ]
;;
