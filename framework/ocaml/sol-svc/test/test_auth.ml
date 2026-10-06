let () = Mirage_crypto_rng_unix.use_default ()
let workload_issuer = "https://kubernetes.default.svc"
let workload_audience = "checkout/checkout-svc"
let caller_service_account = "myapp-payments:charge-svc"
let caller_subject = "system:serviceaccount:" ^ caller_service_account
let caller_unit = "payments/charge-svc"
let rsa_priv_jwk = Jose.Jwk.make_priv_rsa (Mirage_crypto_pk.Rsa.generate ~bits:2048 ())
let rsa_jwks = Jose.Jwks.{ keys = [ Jose.Jwk.pub_of_priv rsa_priv_jwk ] }

let workload_identity ?(callers = [ caller_service_account, caller_unit ]) () =
  Auth.
    { audience = workload_audience
    ; callers
    ; trusted_issuers = [ workload_issuer, "https://cluster.example/jwks" ]
    }
;;

let sign_workload
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
  match Jose.Jwt.sign ~payload rsa_priv_jwk with
  | Ok token -> Jose.Jwt.to_string token
  | Error (`Msg message) -> failwith ("sign_workload: " ^ message)
;;

let headers token = Http.Header.of_list [ "authorization", "Bearer " ^ token ]

let dispatch
      ?(callers = [ caller_service_account, caller_unit ])
      ?(fetch_jwks = fun _ -> Ok rsa_jwks)
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
    ~fetch_jwks
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
  Windtrap.equal
    Windtrap.int
    ~msg:"issuer is not trusted → 401"
    401
    (dispatch (headers (sign_workload ~iss:"https://attacker.example" ())))
      .Response.status
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
  let fetch url =
    incr fetches;
    if url = "https://cluster.example/jwks"
    then Ok rsa_jwks
    else Error "unexpected JWKS URL"
  in
  let token = headers (sign_workload ()) in
  let first = dispatch ~fetch_jwks:fetch token in
  let second = dispatch ~fetch_jwks:fetch token in
  Windtrap.equal Windtrap.int ~msg:"first request succeeds" 200 first.Response.status;
  Windtrap.equal Windtrap.int ~msg:"second request succeeds" 200 second.Response.status;
  Windtrap.equal Windtrap.int ~msg:"cached JWKS is reused" 1 !fetches;
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
        "declared caller authenticates and authorizes"
        test_declared_workload_authenticates_and_authorizes
    ; Windtrap.test "undeclared caller is forbidden" test_undeclared_caller_is_forbidden
    ; Windtrap.test
        "untrusted issuer is unauthorized"
        test_untrusted_issuer_is_unauthorized
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
        "external route bypasses only Sol workload auth"
        test_external_route_bypasses_only_sol_workload_auth
    ]
;;
