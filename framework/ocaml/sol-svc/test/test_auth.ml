let () = Mirage_crypto_rng_unix.use_default ()
let headers_of kv = Http.Header.of_list kv
let bearer tok = headers_of [ "authorization", "Bearer " ^ tok ]
let api_key k = headers_of [ "x-api-key", k ]

let echo_principal req =
  let json =
    match req.Request.auth.Auth.principal with
    | Auth.Public -> `Assoc [ "principal", `String "public" ]
    | Auth.Service { key_id } ->
      `Assoc [ "principal", `String "service"; "key_id", `String key_id ]
    | Auth.User { sub; scopes; _ } ->
      `Assoc
        [ "principal", `String "user"
        ; "sub", `String sub
        ; "scopes", `List (List.map (fun scope -> `String scope) scopes)
        ]
    | Auth.Unit { unit; service_account } ->
      `Assoc
        [ "principal", `String "unit"
        ; "unit", `String unit
        ; "service_account", `String service_account
        ]
  in
  Response.json (Yojson.Safe.to_string json)
;;

let respond ?read_api_key ?fetch_jwks auth headers =
  let request = Http.Request.make ~meth:`GET ~headers "/probe" in
  Service.For_testing.dispatch
    ?read_api_key
    ?fetch_jwks
    ~routes:[ Route.get "/probe" ~auth echo_principal ]
    request
    (Cohttp_eio.Body.of_string "")
;;

let status ?read_api_key ?fetch_jwks auth headers =
  (respond ?read_api_key ?fetch_jwks auth headers).Response.status
;;

let check_status ?read_api_key ?fetch_jwks ~msg expected auth headers =
  Windtrap.equal
    Windtrap.int
    ~msg
    expected
    (status ?read_api_key ?fetch_jwks auth headers)
;;

let rejects_unauthorized ?read_api_key ?fetch_jwks ~msg auth headers =
  check_status ?read_api_key ?fetch_jwks ~msg 401 auth headers
;;

let rejects_forbidden ?read_api_key ?fetch_jwks ~msg auth headers =
  check_status ?read_api_key ?fetch_jwks ~msg 403 auth headers
;;

let rejects_server_error ?read_api_key ?fetch_jwks ~msg auth headers =
  check_status ?read_api_key ?fetch_jwks ~msg 500 auth headers
;;

let principal_json ?read_api_key ?fetch_jwks auth headers =
  let response = respond ?read_api_key ?fetch_jwks auth headers in
  if response.Response.status <> 200
  then
    Windtrap.failf
      "expected 200, got %d: %s"
      response.Response.status
      response.Response.body;
  Yojson.Safe.from_string response.Response.body
;;

let field_string name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> value
  | other ->
    Windtrap.failf "field %s: expected string, got %s" name (Yojson.Safe.to_string other)
;;

let field_strings name json =
  match Yojson.Safe.Util.member name json with
  | `List values ->
    List.filter_map
      (function
        | `String value -> Some value
        | _ -> None)
      values
  | other ->
    Windtrap.failf "field %s: expected list, got %s" name (Yojson.Safe.to_string other)
;;

let test_constant_time_equal () =
  Windtrap.is_true
    ~msg:"the same bytes"
    (Auth.For_testing.constant_time_equal "secret" "secret");
  Windtrap.is_false
    ~msg:"a changed byte"
    (Auth.For_testing.constant_time_equal "secret" "secreu");
  Windtrap.is_false
    ~msg:"a different length"
    (Auth.For_testing.constant_time_equal "secret" "secretx");
  Windtrap.is_true ~msg:"two empty strings" (Auth.For_testing.constant_time_equal "" "")
;;

let test_public () =
  let json = principal_json `Public (headers_of []) in
  Windtrap.equal Windtrap.string ~msg:"principal" "public" (field_string "principal" json)
;;

let configured key () = Some key

let test_api_key_valid () =
  let json =
    principal_json
      ~read_api_key:(configured "secretkey123")
      `Api_key
      (api_key "secretkey123")
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"principal"
    "service"
    (field_string "principal" json);
  Windtrap.equal
    Windtrap.string
    ~msg:"key_id truncated"
    "secretke"
    (field_string "key_id" json)
;;

let test_api_key_wrong () =
  rejects_unauthorized
    ~read_api_key:(configured "secretkey123")
    ~msg:"wrong key → 401"
    `Api_key
    (api_key "wrongkey")
;;

let test_api_key_missing_header () =
  rejects_unauthorized
    ~read_api_key:(configured "secretkey123")
    ~msg:"missing header → 401"
    `Api_key
    (headers_of [])
;;

let test_api_key_without_reader_fails_closed () =
  rejects_server_error
    ~msg:"no reader fails closed → 500"
    `Api_key
    (api_key "secretkey123")
;;

let test_api_key_empty_secret_fails_closed () =
  rejects_server_error
    ~read_api_key:(configured "")
    ~msg:"empty secret fails closed → 500"
    `Api_key
    (api_key "")
;;

let make_jwt ?(sub = "user1") ?(scopes = [ "read" ]) ?(exp_offset = 3600.0) () =
  let header =
    Base64.encode_exn
      ~pad:false
      ~alphabet:Base64.uri_safe_alphabet
      {|{"alg":"HS256","typ":"JWT"}|}
  in
  let now = Unix.gettimeofday () in
  let exp = int_of_float (now +. exp_offset) in
  let scope = String.concat " " scopes in
  let payload = Printf.sprintf {|{"sub":"%s","scope":"%s","exp":%d}|} sub scope exp in
  let payload_b64 =
    Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet payload
  in
  header ^ "." ^ payload_b64 ^ ".fakesig"
;;

let make_jwt_with_payload payload =
  let header =
    Base64.encode_exn
      ~pad:false
      ~alphabet:Base64.uri_safe_alphabet
      {|{"alg":"HS256","typ":"JWT"}|}
  in
  let payload_b64 =
    Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet payload
  in
  header ^ "." ^ payload_b64 ^ ".fakesig"
;;

let jwt_cfg scopes = `Jwt Auth.{ scopes; verification = Unverified_dev_only }

let test_jwt_valid () =
  let json =
    principal_json
      (jwt_cfg [ "read"; "write" ])
      (bearer (make_jwt ~scopes:[ "read"; "write" ] ()))
  in
  Windtrap.equal Windtrap.string ~msg:"sub" "user1" (field_string "sub" json);
  Windtrap.equal
    Windtrap.bool
    ~msg:"scopes"
    true
    (List.mem "write" (field_strings "scopes" json))
;;

let test_jwt_superset_scopes () =
  let json =
    principal_json
      (jwt_cfg [ "read" ])
      (bearer (make_jwt ~scopes:[ "read"; "write"; "admin" ] ()))
  in
  Windtrap.equal Windtrap.string ~msg:"principal" "user" (field_string "principal" json)
;;

let test_jwt_missing_scope () =
  rejects_forbidden
    ~msg:"missing scope → 403"
    (jwt_cfg [ "read"; "write" ])
    (bearer (make_jwt ~scopes:[ "read" ] ()))
;;

let test_jwt_expired () =
  rejects_unauthorized
    ~msg:"expired → 401"
    (jwt_cfg [])
    (bearer (make_jwt ~exp_offset:(-1.0) ()))
;;

let test_jwt_malformed () =
  rejects_unauthorized
    ~msg:"malformed → 401"
    (jwt_cfg [])
    (bearer "not.a.jwt.at.all.extra")
;;

let test_jwt_wrong_bearer_scheme () =
  rejects_unauthorized
    ~msg:"wrong bearer → 401"
    (jwt_cfg [])
    (headers_of [ "authorization", "Token abc" ])
;;

let test_jwt_payload_not_base64 () =
  rejects_unauthorized
    ~msg:"bad payload b64 → 401"
    (jwt_cfg [])
    (bearer "header.%.signature")
;;

let test_jwt_payload_not_json () =
  rejects_unauthorized
    ~msg:"bad payload JSON → 401"
    (jwt_cfg [])
    (bearer (make_jwt_with_payload "not json"))
;;

let test_jwt_payload_not_an_object () =
  rejects_unauthorized
    ~msg:"non-object payload → 401"
    (jwt_cfg [])
    (bearer (make_jwt_with_payload "[]"))
;;

let test_jwt_missing_header () =
  rejects_unauthorized ~msg:"missing header → 401" (jwt_cfg []) (headers_of [])
;;

let issuer = "https://issuer.example.com"
let audience = "sol-svc-test"

let claims_json ~sub ~scopes ~iss ~aud ~exp_offset =
  let now = Unix.gettimeofday () in
  let exp = int_of_float (now +. exp_offset) in
  `Assoc
    [ "sub", `String sub
    ; "scope", `String (String.concat " " scopes)
    ; "iss", `String iss
    ; "aud", `String aud
    ; "exp", `Int exp
    ]
;;

let hs256_secret = "test-hs256-shared-secret"

let sign_hs256
      ?(sub = "user1")
      ?(scopes = [ "read" ])
      ?(iss = issuer)
      ?(aud = audience)
      ?(exp_offset = 3600.0)
      ()
  =
  let jwk = Jose.Jwk.make_oct hs256_secret in
  let payload = claims_json ~sub ~scopes ~iss ~aud ~exp_offset in
  match Jose.Jwt.sign ~payload jwk with
  | Ok t -> Jose.Jwt.to_string t
  | Error (`Msg m) -> failwith ("sign_hs256: " ^ m)
;;

let hs256_verified_cfg
      ?(scopes = [])
      ?(algorithms = [ `HS256 ])
      ?(issuer = issuer)
      ?(audience = audience)
      ()
  =
  `Jwt
    Auth.
      { scopes
      ; verification =
          Verified_signature_required
            { issuer; audience; algorithms; key_source = Hs256_secret hs256_secret }
      }
;;

let rsa_priv_jwk = Jose.Jwk.make_priv_rsa (Mirage_crypto_pk.Rsa.generate ~bits:2048 ())

let rsa_jwks_doc =
  Jose.Jwks.to_string { Jose.Jwks.keys = [ Jose.Jwk.pub_of_priv rsa_priv_jwk ] }
;;

let sign_rs256
      ?(sub = "user1")
      ?(scopes = [ "read" ])
      ?(iss = issuer)
      ?(aud = audience)
      ?(exp_offset = 3600.0)
      ()
  =
  let payload = claims_json ~sub ~scopes ~iss ~aud ~exp_offset in
  match Jose.Jwt.sign ~payload rsa_priv_jwk with
  | Ok t -> Jose.Jwt.to_string t
  | Error (`Msg m) -> failwith ("sign_rs256: " ^ m)
;;

let rs256_verified_cfg
      ?(scopes = [])
      ?(algorithms = [ `RS256 ])
      ?(issuer = issuer)
      ?(audience = audience)
      ()
  =
  `Jwt
    Auth.
      { scopes
      ; verification =
          Verified_signature_required
            { issuer; audience; algorithms; key_source = Jwks_static rsa_jwks_doc }
      }
;;

let tamper_signature token =
  match String.rindex_opt token '.' with
  | None -> token
  | Some i ->
    let prefix = String.sub token 0 (i + 1) in
    let sig_part = String.sub token (i + 1) (String.length token - i - 1) in
    let flipped =
      String.mapi
        (fun idx c -> if idx = 0 then if c = 'A' then 'B' else 'A' else c)
        sig_part
    in
    prefix ^ flipped
;;

let test_jwt_verified_hs256_valid () =
  let json =
    principal_json
      (hs256_verified_cfg ~scopes:[ "read"; "write" ] ())
      (bearer (sign_hs256 ~scopes:[ "read"; "write" ] ()))
  in
  Windtrap.equal Windtrap.string ~msg:"sub" "user1" (field_string "sub" json);
  Windtrap.equal
    Windtrap.bool
    ~msg:"scopes"
    true
    (List.mem "write" (field_strings "scopes" json))
;;

let test_jwt_verified_rs256_valid () =
  let json =
    principal_json
      (rs256_verified_cfg ~scopes:[ "read" ] ())
      (bearer (sign_rs256 ~scopes:[ "read" ] ()))
  in
  Windtrap.equal Windtrap.string ~msg:"sub" "user1" (field_string "sub" json)
;;

let test_jwt_verified_tampered_signature () =
  rejects_unauthorized
    ~msg:"tampered signature → 401"
    (hs256_verified_cfg ())
    (bearer (tamper_signature (sign_hs256 ())))
;;

let test_jwt_verified_wrong_alg_rejected () =
  rejects_unauthorized
    ~msg:"alg not in allowlist → 401"
    (hs256_verified_cfg ~algorithms:[ `RS256 ] ())
    (bearer (sign_hs256 ()))
;;

let test_jwt_verified_wrong_issuer () =
  rejects_unauthorized
    ~msg:"wrong issuer → 401"
    (hs256_verified_cfg ())
    (bearer (sign_hs256 ~iss:"https://someone-else.example.com" ()))
;;

let test_jwt_verified_wrong_audience () =
  rejects_unauthorized
    ~msg:"wrong audience → 401"
    (hs256_verified_cfg ())
    (bearer (sign_hs256 ~aud:"someone-else" ()))
;;

let test_jwt_verified_expired () =
  rejects_unauthorized
    ~msg:"expired → 401"
    (hs256_verified_cfg ())
    (bearer (sign_hs256 ~exp_offset:(-1.0) ()))
;;

let sign_claims payload =
  match Jose.Jwt.sign ~payload (Jose.Jwk.make_oct hs256_secret) with
  | Ok t -> Jose.Jwt.to_string t
  | Error (`Msg m) -> failwith ("sign_claims: " ^ m)
;;

let verified_claims ?(sub = "user1") ?(scopes = [ "read" ]) temporal =
  `Assoc
    ([ "sub", `String sub
     ; "scope", `String (String.concat " " scopes)
     ; "iss", `String issuer
     ; "aud", `String audience
     ]
     @ temporal)
;;

let check_rejected ~msg token =
  rejects_unauthorized ~msg (hs256_verified_cfg ()) (bearer token)
;;

let check_accepted ~msg token =
  let json = principal_json (hs256_verified_cfg ()) (bearer token) in
  Windtrap.equal
    Windtrap.string
    ~msg:(msg ^ ": principal")
    "user"
    (field_string "principal" json)
;;

let test_jwt_verified_future_nbf_rejected () =
  let now = Unix.gettimeofday () in
  check_rejected
    ~msg:"nbf one hour ahead"
    (sign_claims
       (verified_claims
          [ "nbf", `Int (int_of_float (now +. 3600.))
          ; "exp", `Int (int_of_float (now +. 7200.))
          ]))
;;

let test_jwt_verified_current_nbf_accepted () =
  let now = Unix.gettimeofday () in
  check_accepted
    ~msg:"nbf one second ago"
    (sign_claims
       (verified_claims
          [ "nbf", `Int (int_of_float (now -. 1.))
          ; "exp", `Int (int_of_float (now +. 3600.))
          ]))
;;

let test_jwt_verified_fractional_numeric_dates () =
  let now = Unix.gettimeofday () in
  check_accepted
    ~msg:"fractional nbf/exp in range"
    (sign_claims
       (verified_claims [ "nbf", `Float (now -. 1.); "exp", `Float (now +. 3600.) ]));
  check_rejected
    ~msg:"fractional exp in the past"
    (sign_claims (verified_claims [ "exp", `Float (now -. 3600.) ]));
  check_rejected
    ~msg:"fractional nbf in the future"
    (sign_claims
       (verified_claims [ "nbf", `Float (now +. 3600.); "exp", `Float (now +. 7200.) ]))
;;

let test_jwt_verified_malformed_temporal_claims () =
  let now = Unix.gettimeofday () in
  let exp_in_range = `Int (int_of_float (now +. 3600.)) in
  List.iter
    (fun (label, temporal) ->
       check_rejected ~msg:label (sign_claims (verified_claims temporal)))
    [ "exp is a string", [ "exp", `String "soon" ]
    ; "exp is an array", [ "exp", `List [] ]
    ; "exp is an object", [ "exp", `Assoc [] ]
    ; "nbf is a string", [ "nbf", `String "later"; "exp", exp_in_range ]
    ; "nbf is a boolean", [ "nbf", `Bool true; "exp", exp_in_range ]
    ]
;;

let test_jwt_verified_missing_scope () =
  rejects_forbidden
    ~msg:"missing scope → 403"
    (hs256_verified_cfg ~scopes:[ "read"; "write" ] ())
    (bearer (sign_hs256 ~scopes:[ "read" ] ()))
;;

let jwks_url_cfg () =
  `Jwt
    Auth.
      { scopes = []
      ; verification =
          Verified_signature_required
            { issuer
            ; audience
            ; algorithms = [ `RS256 ]
            ; key_source = Jwks_url "https://idp.example.com/jwks.json"
            }
      }
;;

let test_jwt_verified_jwks_fetch_failure_fails_closed () =
  rejects_server_error
    ~fetch_jwks:(fun _url -> Error "connection refused")
    ~msg:"JWKS fetch failure fails closed → 500"
    (jwks_url_cfg ())
    (bearer (sign_rs256 ()))
;;

let test_jwt_verified_jwks_url_without_fetcher_fails_closed () =
  rejects_server_error
    ~msg:"Jwks_url with no fetcher fails closed → 500"
    (jwks_url_cfg ())
    (bearer (sign_rs256 ()))
;;

let test_jwt_verified_malformed_static_jwks_fails_closed () =
  let cfg =
    `Jwt
      Auth.
        { scopes = []
        ; verification =
            Verified_signature_required
              { issuer
              ; audience
              ; algorithms = [ `RS256 ]
              ; key_source = Jwks_static "not json"
              }
        }
  in
  rejects_server_error
    ~msg:"malformed static JWKS fails closed → 500"
    cfg
    (bearer (sign_rs256 ()))
;;

let jwks_cfg_for url =
  `Jwt
    Auth.
      { scopes = []
      ; verification =
          Verified_signature_required
            { issuer; audience; algorithms = [ `RS256 ]; key_source = Jwks_url url }
      }
;;

let empty_jwks_doc = Jose.Jwks.to_string { Jose.Jwks.keys = [] }

let test_concurrent_cache_misses_share_one_fetch () =
  Eio_main.run
  @@ fun env ->
  let url = "https://idp.example.com/concurrent/jwks.json" in
  let fetches = ref 0 in
  let slow_fetch _ =
    incr fetches;
    Eio.Time.sleep env#clock 0.1;
    Ok (Jose.Jwks.of_string rsa_jwks_doc)
  in
  let probe () =
    status ~fetch_jwks:slow_fetch (jwks_cfg_for url) (bearer (sign_rs256 ()))
  in
  let a, b = Eio.Fiber.pair probe probe in
  Windtrap.equal
    (Windtrap.pair Windtrap.int Windtrap.int)
    ~msg:"both requests verified"
    (200, 200)
    (a, b);
  Windtrap.equal Windtrap.int ~msg:"one fetch served both" 1 !fetches
;;

let test_unknown_kid_refetches () =
  let url = "https://idp.example.com/rotated/jwks.json" in
  Auth.For_testing.seed_stale_jwks_cache ~url ~age_s:60.0 ~jwks:empty_jwks_doc;
  let fetches = ref 0 in
  let fetch _ =
    incr fetches;
    Ok (Jose.Jwks.of_string rsa_jwks_doc)
  in
  check_status
    ~fetch_jwks:fetch
    ~msg:"a key rotated in after the last fetch is found"
    200
    (jwks_cfg_for url)
    (bearer (sign_rs256 ()));
  Windtrap.equal Windtrap.int ~msg:"refetched once" 1 !fetches
;;

let test_unknown_kid_refetch_is_rate_limited () =
  let url = "https://idp.example.com/recent/jwks.json" in
  Auth.For_testing.seed_stale_jwks_cache ~url ~age_s:5.0 ~jwks:empty_jwks_doc;
  let fetches = ref 0 in
  let fetch _ =
    incr fetches;
    Ok (Jose.Jwks.of_string rsa_jwks_doc)
  in
  check_status
    ~fetch_jwks:fetch
    ~msg:"no refetch inside the interval → 401"
    401
    (jwks_cfg_for url)
    (bearer (sign_rs256 ()));
  Windtrap.equal Windtrap.int ~msg:"no refetch inside the interval" 0 !fetches
;;

let test_failed_fetch_is_shared_not_repeated () =
  Eio_main.run
  @@ fun env ->
  let url = "https://idp.example.com/outage/jwks.json" in
  let fetches = ref 0 in
  let failing_fetch _ =
    incr fetches;
    Eio.Time.sleep env#clock 0.1;
    Error "connection refused"
  in
  let tok = sign_rs256 () in
  let probe () =
    check_status
      ~fetch_jwks:failing_fetch
      ~msg:"the IdP is down → 500"
      500
      (jwks_cfg_for url)
      (bearer tok)
  in
  Eio.Fiber.all [ probe; probe; probe; probe; probe ];
  Windtrap.equal Windtrap.int ~msg:"one fetch for five waiting requests" 1 !fetches
;;

let test_unknown_kid_with_failed_refetch_is_401 () =
  let url = "https://idp.example.com/down-rotated/jwks.json" in
  Auth.For_testing.seed_stale_jwks_cache ~url ~age_s:60.0 ~jwks:empty_jwks_doc;
  rejects_unauthorized
    ~fetch_jwks:(fun _ -> Error "connection refused")
    ~msg:"an unknown kid is a 401 even when the refetch fails"
    (jwks_cfg_for url)
    (bearer (sign_rs256 ()))
;;

(* DEC-063: Sol-to-Sol workload identity *)

let workload_issuer = "https://kubernetes.default.svc"
let workload_audience = "checkout/checkout-svc"
let caller_service_account = "myapp-payments:charge-svc"
let caller_subject = "system:serviceaccount:" ^ caller_service_account
let caller_unit = "payments/charge-svc"

let workload_identity ?(callers = [ caller_service_account, caller_unit ]) () =
  Auth.
    { audience = workload_audience
    ; callers
    ; trusted_issuers =
        [ workload_issuer, "https://kubernetes.default.svc/openid/v1/jwks" ]
    }
;;

let fetch_static_jwks _url = Ok (Jose.Jwks.of_string rsa_jwks_doc)

let sign_workload
      ?(sub = caller_subject)
      ?(aud = workload_audience)
      ?(iss = workload_issuer)
      ?(exp_offset = 3600.0)
      ()
  =
  let payload = claims_json ~sub ~scopes:[] ~iss ~aud ~exp_offset in
  match Jose.Jwt.sign ~payload rsa_priv_jwk with
  | Ok t -> Jose.Jwt.to_string t
  | Error (`Msg m) -> failwith ("sign_workload: " ^ m)
;;

let workload_dispatch ?(callers = [ caller_service_account, caller_unit ]) headers =
  Service.For_testing.dispatch
    ~fetch_jwks:fetch_static_jwks
    ~workload_identity:(workload_identity ~callers ())
    ~routes:[ Route.get "/probe" echo_principal ]
    (Http.Request.make ~meth:`GET ~headers "/probe")
    (Cohttp_eio.Body.of_string "")
;;

let workload_status ?callers headers =
  (workload_dispatch ?callers headers).Response.status
;;

let test_workload_identity_authenticates_and_authorizes () =
  let json =
    Yojson.Safe.from_string (workload_dispatch (bearer (sign_workload ()))).Response.body
  in
  Windtrap.equal Windtrap.string ~msg:"principal" "unit" (field_string "principal" json);
  Windtrap.equal Windtrap.string ~msg:"unit" caller_unit (field_string "unit" json);
  Windtrap.equal
    Windtrap.string
    ~msg:"service account"
    caller_service_account
    (field_string "service_account" json)
;;

let test_workload_identity_undeclared_caller_is_forbidden () =
  Windtrap.equal
    Windtrap.int
    ~msg:"an authenticated but undeclared caller → 403"
    403
    (workload_status ~callers:[] (bearer (sign_workload ())))
;;

let test_workload_identity_untrusted_issuer_is_unauthorized () =
  Windtrap.equal
    Windtrap.int
    ~msg:"an untrusted issuer → 401"
    401
    (workload_status (bearer (sign_workload ~iss:"https://someone-else.example.com" ())))
;;

let test_workload_identity_wrong_audience_is_unauthorized () =
  Windtrap.equal
    Windtrap.int
    ~msg:"a token minted for another unit → 401"
    401
    (workload_status (bearer (sign_workload ~aud:"payments/other-svc" ())))
;;

let test_workload_identity_tampered_signature_is_unauthorized () =
  Windtrap.equal
    Windtrap.int
    ~msg:"a tampered signature → 401"
    401
    (workload_status (bearer (tamper_signature (sign_workload ()))))
;;

let test_workload_identity_non_service_account_is_forbidden () =
  Windtrap.equal
    Windtrap.int
    ~msg:"a verified but non-workload subject → 403"
    403
    (workload_status (bearer (sign_workload ~sub:"user1" ())))
;;

let test_workload_identity_missing_token_is_unauthorized () =
  Windtrap.equal Windtrap.int ~msg:"no token → 401" 401 (workload_status (headers_of []))
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () -> Unix.putenv name (Option.value old ~default:""))
;;

let test_workload_identity_config_requires_unit () =
  with_env "SOL_UNIT" "" (fun () ->
    match
      Service.For_testing.workload_identity_config
        ~trusted_issuers:[ workload_issuer, "https://x/jwks" ]
        [ Route.get "/probe" echo_principal ]
        `Workload_identity
    with
    | Error (`Config msg) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names SOL_UNIT"
        true
        (Sol_runtime.contains_substring ~needle:"SOL_UNIT" msg)
    | Ok _ -> Windtrap.fail "a workload-identity route without SOL_UNIT must fail closed")
;;

let test_workload_identity_config_requires_a_trust_root () =
  with_env "SOL_UNIT" workload_audience (fun () ->
    match
      Service.For_testing.workload_identity_config
        ~trusted_issuers:[]
        [ Route.get "/probe" echo_principal ]
        `Workload_identity
    with
    | Error (`Config msg) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the trust root"
        true
        (Sol_runtime.contains_substring ~needle:"trust" msg)
    | Ok _ ->
      Windtrap.fail "a workload-identity route without a trust root must fail closed")
;;

let test_workload_identity_config_reads_the_declared_graph () =
  with_env "SOL_UNIT" workload_audience (fun () ->
    with_env
      "SOL_CALLED_BY"
      (caller_unit ^ "=" ^ caller_service_account)
      (fun () ->
         match
           Service.For_testing.workload_identity_config
             ~trusted_issuers:[ workload_issuer, "https://x/jwks" ]
             [ Route.get "/probe" echo_principal ]
             `Workload_identity
         with
         | Error err -> Windtrap.fail (Service.run_error_to_string err)
         | Ok None ->
           Windtrap.fail "workload identity was requested, so a config is required"
         | Ok (Some config) ->
           Windtrap.equal
             Windtrap.string
             ~msg:"audience is the callee's unit"
             workload_audience
             config.Auth.audience;
           Windtrap.equal
             (Windtrap.option Windtrap.string)
             ~msg:"the declared called_by maps the service account to the caller unit"
             (Some caller_unit)
             (List.assoc_opt caller_service_account config.Auth.callers)))
;;

let () =
  Windtrap.run
    "auth"
    [ Windtrap.group
        "auth.for_testing"
        [ Windtrap.test "constant-time comparison" test_constant_time_equal ]
    ; Windtrap.group "public" [ Windtrap.test "returns Public principal" test_public ]
    ; Windtrap.group
        "api_key"
        [ Windtrap.test "valid key" test_api_key_valid
        ; Windtrap.test "wrong key → 401" test_api_key_wrong
        ; Windtrap.test "missing header → 401" test_api_key_missing_header
        ; Windtrap.test "no reader fails closed" test_api_key_without_reader_fails_closed
        ; Windtrap.test "empty secret fails closed" test_api_key_empty_secret_fails_closed
        ]
    ; Windtrap.group
        "jwt_unverified"
        [ Windtrap.test "valid token" test_jwt_valid
        ; Windtrap.test "superset scopes → ok" test_jwt_superset_scopes
        ; Windtrap.test "missing scope → 403" test_jwt_missing_scope
        ; Windtrap.test "expired → 401" test_jwt_expired
        ; Windtrap.test "malformed → 401" test_jwt_malformed
        ; Windtrap.test "wrong bearer → 401" test_jwt_wrong_bearer_scheme
        ; Windtrap.test "bad payload b64 → 401" test_jwt_payload_not_base64
        ; Windtrap.test "bad payload JSON → 401" test_jwt_payload_not_json
        ; Windtrap.test "non-object payload → 401" test_jwt_payload_not_an_object
        ; Windtrap.test "missing header → 401" test_jwt_missing_header
        ]
    ; Windtrap.group
        "jwt_verified"
        [ Windtrap.test "HS256 valid → ok" test_jwt_verified_hs256_valid
        ; Windtrap.test "RS256 valid (JWKS) → ok" test_jwt_verified_rs256_valid
        ; Windtrap.test "tampered signature → 401" test_jwt_verified_tampered_signature
        ; Windtrap.test "alg not in allowlist → 401" test_jwt_verified_wrong_alg_rejected
        ; Windtrap.test "wrong issuer → 401" test_jwt_verified_wrong_issuer
        ; Windtrap.test "wrong audience → 401" test_jwt_verified_wrong_audience
        ; Windtrap.test "expired → 401" test_jwt_verified_expired
        ; Windtrap.test "future nbf → 401 (BUG-079)" test_jwt_verified_future_nbf_rejected
        ; Windtrap.test
            "current nbf → ok (BUG-079)"
            test_jwt_verified_current_nbf_accepted
        ; Windtrap.test
            "fractional NumericDate boundaries (BUG-079)"
            test_jwt_verified_fractional_numeric_dates
        ; Windtrap.test
            "malformed temporal claims → 401 (BUG-079)"
            test_jwt_verified_malformed_temporal_claims
        ; Windtrap.test "missing scope → 403" test_jwt_verified_missing_scope
        ; Windtrap.test
            "JWKS fetch failure fails closed → 500"
            test_jwt_verified_jwks_fetch_failure_fails_closed
        ; Windtrap.test
            "Jwks_url with no fetcher fails closed → 500"
            test_jwt_verified_jwks_url_without_fetcher_fails_closed
        ; Windtrap.test
            "malformed static JWKS fails closed → 500"
            test_jwt_verified_malformed_static_jwks_fails_closed
        ]
    ; Windtrap.group
        "jwks (BUG-053)"
        [ Windtrap.test
            "concurrent cache misses share one fetch"
            test_concurrent_cache_misses_share_one_fetch
        ; Windtrap.test "unknown kid refetches" test_unknown_kid_refetches
        ; Windtrap.test
            "unknown kid refetch is rate-limited"
            test_unknown_kid_refetch_is_rate_limited
        ; Windtrap.test
            "failed fetch is shared, not repeated"
            test_failed_fetch_is_shared_not_repeated
        ; Windtrap.test
            "unknown kid with failed refetch → 401"
            test_unknown_kid_with_failed_refetch_is_401
        ]
    ; Windtrap.group
        "workload_identity (DEC-063)"
        [ Windtrap.test
            "a declared caller authenticates and authorizes"
            test_workload_identity_authenticates_and_authorizes
        ; Windtrap.test
            "an undeclared caller → 403"
            test_workload_identity_undeclared_caller_is_forbidden
        ; Windtrap.test
            "an untrusted issuer → 401"
            test_workload_identity_untrusted_issuer_is_unauthorized
        ; Windtrap.test
            "a token for another audience → 401"
            test_workload_identity_wrong_audience_is_unauthorized
        ; Windtrap.test
            "a tampered signature → 401"
            test_workload_identity_tampered_signature_is_unauthorized
        ; Windtrap.test
            "a verified non-workload subject → 403"
            test_workload_identity_non_service_account_is_forbidden
        ; Windtrap.test
            "no token → 401"
            test_workload_identity_missing_token_is_unauthorized
        ; Windtrap.test
            "no SOL_UNIT fails closed"
            test_workload_identity_config_requires_unit
        ; Windtrap.test
            "no trust root fails closed"
            test_workload_identity_config_requires_a_trust_root
        ; Windtrap.test
            "the declared graph supplies audience and callers"
            test_workload_identity_config_reads_the_declared_graph
        ]
    ]
;;
