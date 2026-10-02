let () = Mirage_crypto_rng_unix.use_default ()
let headers_of kv = Http.Header.of_list kv
let bearer tok = headers_of [ "authorization", "Bearer " ^ tok ]
let api_key k = headers_of [ "x-api-key", k ]

let test_public () =
  match Test_auth_internal.validate `Public (headers_of []) with
  | Ok { principal = Auth.Public } -> ()
  | _ -> Windtrap.fail "expected Public principal"
;;

let test_api_key_valid () =
  let read_api_key () = Some "secretkey123" in
  match Test_auth_internal.validate ~read_api_key `Api_key (api_key "secretkey123") with
  | Ok { principal = Auth.Service { key_id } } ->
    Windtrap.equal Windtrap.string ~msg:"key_id truncated" "secretke" key_id
  | _ -> Windtrap.fail "expected Service principal"
;;

let test_api_key_wrong () =
  let read_api_key () = Some "secretkey123" in
  match Test_auth_internal.validate ~read_api_key `Api_key (api_key "wrongkey") with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized"
;;

let test_api_key_missing_header () =
  let read_api_key () = Some "secretkey123" in
  match Test_auth_internal.validate ~read_api_key `Api_key (headers_of []) with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized"
;;

let test_api_key_without_reader_fails_closed () =
  match Test_auth_internal.validate `Api_key (api_key "secretkey123") with
  | Error (`Server_error _) -> ()
  | _ -> Windtrap.fail "expected Server_error"
;;

let test_api_key_uses_injected_reader () =
  let read_api_key () = Some "secretkey123" in
  match Test_auth_internal.validate ~read_api_key `Api_key (api_key "secretkey123") with
  | Ok { principal = Auth.Service { key_id } } ->
    Windtrap.equal Windtrap.string ~msg:"key_id truncated" "secretke" key_id
  | _ -> Windtrap.fail "expected Service principal"
;;

let test_api_key_empty_secret_fails_closed () =
  let read_api_key () = Some "" in
  match Test_auth_internal.validate ~read_api_key `Api_key (api_key "") with
  | Error (`Server_error _) -> ()
  | Ok _ -> Windtrap.fail "empty API key must not authenticate"
  | Error _ -> Windtrap.fail "expected Server_error for empty configured API key"
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
  let tok = make_jwt ~scopes:[ "read"; "write" ] () in
  match Test_auth_internal.validate (jwt_cfg [ "read"; "write" ]) (bearer tok) with
  | Ok { principal = Auth.User { sub; scopes; _ } } ->
    Windtrap.equal Windtrap.string ~msg:"sub" "user1" sub;
    Windtrap.equal Windtrap.bool ~msg:"scopes" true (List.mem "write" scopes)
  | _ -> Windtrap.fail "expected User principal"
;;

let test_jwt_superset_scopes () =
  let tok = make_jwt ~scopes:[ "read"; "write"; "admin" ] () in
  match Test_auth_internal.validate (jwt_cfg [ "read" ]) (bearer tok) with
  | Ok { principal = Auth.User _ } -> ()
  | _ -> Windtrap.fail "expected User principal"
;;

let test_jwt_missing_scope () =
  let tok = make_jwt ~scopes:[ "read" ] () in
  match Test_auth_internal.validate (jwt_cfg [ "read"; "write" ]) (bearer tok) with
  | Error (`Forbidden msg) ->
    Windtrap.equal Windtrap.bool ~msg:"mentions missing scope" true (String.length msg > 0)
  | _ -> Windtrap.fail "expected Forbidden"
;;

let test_jwt_expired () =
  let tok = make_jwt ~exp_offset:(-1.0) () in
  match Test_auth_internal.validate (jwt_cfg []) (bearer tok) with
  | Error (`Unauthorized msg) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"expired message"
      true
      (let m = String.lowercase_ascii msg in
       String.length m > 0)
  | _ -> Windtrap.fail "expected Unauthorized"
;;

let test_jwt_malformed () =
  match Test_auth_internal.validate (jwt_cfg []) (bearer "not.a.jwt.at.all.extra") with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized"
;;

let test_jwt_wrong_bearer_scheme () =
  match
    Test_auth_internal.validate (jwt_cfg []) (headers_of [ "authorization", "Token abc" ])
  with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized"
;;

let test_jwt_payload_not_base64 () =
  match Test_auth_internal.validate (jwt_cfg []) (bearer "header.%.signature") with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized"
;;

let test_jwt_payload_not_json () =
  match
    Test_auth_internal.validate (jwt_cfg []) (bearer (make_jwt_with_payload "not json"))
  with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized"
;;

let test_jwt_missing_header () =
  match Test_auth_internal.validate (jwt_cfg []) (headers_of []) with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized"
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
  let tok = sign_hs256 ~scopes:[ "read"; "write" ] () in
  match
    Test_auth_internal.validate
      (hs256_verified_cfg ~scopes:[ "read"; "write" ] ())
      (bearer tok)
  with
  | Ok { principal = Auth.User { sub; scopes; _ } } ->
    Windtrap.equal Windtrap.string ~msg:"sub" "user1" sub;
    Windtrap.equal Windtrap.bool ~msg:"scopes" true (List.mem "write" scopes)
  | _ -> Windtrap.fail "expected User principal"
;;

let test_jwt_verified_rs256_valid () =
  let tok = sign_rs256 ~scopes:[ "read" ] () in
  match
    Test_auth_internal.validate (rs256_verified_cfg ~scopes:[ "read" ] ()) (bearer tok)
  with
  | Ok { principal = Auth.User { sub; _ } } ->
    Windtrap.equal Windtrap.string ~msg:"sub" "user1" sub
  | _ -> Windtrap.fail "expected User principal"
;;

let test_jwt_verified_tampered_signature () =
  let tok = tamper_signature (sign_hs256 ()) in
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer tok) with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized (invalid signature)"
;;

let test_jwt_verified_wrong_alg_rejected () =
  let tok = sign_hs256 () in
  match
    Test_auth_internal.validate
      (hs256_verified_cfg ~algorithms:[ `RS256 ] ())
      (bearer tok)
  with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized (alg not permitted)"
;;

let test_jwt_verified_wrong_issuer () =
  let tok = sign_hs256 ~iss:"https://someone-else.example.com" () in
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer tok) with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized (issuer mismatch)"
;;

let test_jwt_verified_wrong_audience () =
  let tok = sign_hs256 ~aud:"someone-else" () in
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer tok) with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized (audience mismatch)"
;;

let test_jwt_verified_expired () =
  let tok = sign_hs256 ~exp_offset:(-1.0) () in
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer tok) with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "expected Unauthorized (expired)"
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

let check_unauthorized label token =
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer token) with
  | Error (`Unauthorized _) -> ()
  | Error _ -> Windtrap.fail (label ^ ": expected Unauthorized")
  | Ok _ -> Windtrap.fail (label ^ ": expected rejection")
;;

let check_authenticated label token =
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer token) with
  | Ok { principal = Auth.User _ } -> ()
  | Error (`Unauthorized m) -> Windtrap.fail (label ^ ": rejected: " ^ m)
  | _ -> Windtrap.fail (label ^ ": expected User principal")
;;

let test_jwt_verified_future_nbf_rejected () =
  let now = Unix.gettimeofday () in
  check_unauthorized
    "nbf one hour ahead"
    (sign_claims
       (verified_claims
          [ "nbf", `Int (int_of_float (now +. 3600.))
          ; "exp", `Int (int_of_float (now +. 7200.))
          ]))
;;

let test_jwt_verified_current_nbf_accepted () =
  let now = Unix.gettimeofday () in
  check_authenticated
    "nbf one second ago"
    (sign_claims
       (verified_claims
          [ "nbf", `Int (int_of_float (now -. 1.))
          ; "exp", `Int (int_of_float (now +. 3600.))
          ]))
;;

let test_jwt_verified_fractional_numeric_dates () =
  let now = Unix.gettimeofday () in
  check_authenticated
    "fractional nbf/exp in range"
    (sign_claims
       (verified_claims [ "nbf", `Float (now -. 1.); "exp", `Float (now +. 3600.) ]));
  check_unauthorized
    "fractional exp in the past"
    (sign_claims (verified_claims [ "exp", `Float (now -. 3600.) ]));
  check_unauthorized
    "fractional nbf in the future"
    (sign_claims
       (verified_claims [ "nbf", `Float (now +. 3600.); "exp", `Float (now +. 7200.) ]))
;;

let test_jwt_verified_malformed_temporal_claims () =
  let now = Unix.gettimeofday () in
  let exp_in_range = `Int (int_of_float (now +. 3600.)) in
  List.iter
    (fun (label, temporal) ->
       check_unauthorized label (sign_claims (verified_claims temporal)))
    [ "exp is a string", [ "exp", `String "soon" ]
    ; "exp is an array", [ "exp", `List [] ]
    ; "exp is an object", [ "exp", `Assoc [] ]
    ; "nbf is a string", [ "nbf", `String "later"; "exp", exp_in_range ]
    ; "nbf is a boolean", [ "nbf", `Bool true; "exp", exp_in_range ]
    ]
;;

let test_jwt_verified_missing_scope () =
  let tok = sign_hs256 ~scopes:[ "read" ] () in
  match
    Test_auth_internal.validate
      (hs256_verified_cfg ~scopes:[ "read"; "write" ] ())
      (bearer tok)
  with
  | Error (`Forbidden _) -> ()
  | _ -> Windtrap.fail "expected Forbidden (missing scope)"
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
  let tok = sign_rs256 () in
  let failing_fetch _url = Error "connection refused" in
  match
    Test_auth_internal.validate ~fetch_jwks:failing_fetch (jwks_url_cfg ()) (bearer tok)
  with
  | Error (`Server_error _) -> ()
  | Ok _ -> Windtrap.fail "must not fall back to unverified on JWKS fetch failure"
  | Error _ -> Windtrap.fail "expected Server_error (fail closed)"
;;

let test_jwt_verified_jwks_url_without_fetcher_fails_closed () =
  let tok = sign_rs256 () in
  match Test_auth_internal.validate (jwks_url_cfg ()) (bearer tok) with
  | Error (`Server_error _) -> ()
  | Ok _ -> Windtrap.fail "must not fall back to unverified with no fetch_jwks configured"
  | Error _ -> Windtrap.fail "expected Server_error (fail closed)"
;;

let test_jwt_verified_malformed_static_jwks_fails_closed () =
  let tok = sign_rs256 () in
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
  match Test_auth_internal.validate cfg (bearer tok) with
  | Error (`Server_error _) -> ()
  | Ok _ -> Windtrap.fail "malformed static JWKS must not authenticate"
  | Error _ -> Windtrap.fail "expected Server_error for malformed static JWKS"
;;

let test_jwt_payload_not_an_object () =
  match
    Test_auth_internal.validate (jwt_cfg []) (bearer (make_jwt_with_payload "[]"))
  with
  | Error (`Unauthorized _) -> ()
  | Error _ -> Windtrap.fail "expected Unauthorized"
  | Ok _ -> Windtrap.fail "a non-object payload must be rejected"
  | exception e ->
    Windtrap.failf "a non-object payload must be a 401, not %s" (Printexc.to_string e)
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
  let tok = sign_rs256 () in
  let validate () =
    match
      Test_auth_internal.validate ~fetch_jwks:slow_fetch (jwks_cfg_for url) (bearer tok)
    with
    | Ok _ -> "ok"
    | Error (`Unauthorized m | `Forbidden m | `Server_error m) -> "error: " ^ m
    | exception e -> "raised: " ^ Printexc.to_string e
  in
  let a, b = Eio.Fiber.pair validate validate in
  Windtrap.equal
    (Windtrap.pair Windtrap.string Windtrap.string)
    ~msg:"both requests verified"
    ("ok", "ok")
    (a, b);
  Windtrap.equal Windtrap.int ~msg:"one fetch served both" 1 !fetches
;;

let seed_jwks_cache ~url ~age_s doc =
  Atomic.set
    Test_auth_internal.jwks_cache
    (Some
       { Test_auth_internal.url
       ; fetched_at = Unix.gettimeofday () -. age_s
       ; jwks = Jose.Jwks.of_string doc
       })
;;

let empty_jwks_doc = Jose.Jwks.to_string { Jose.Jwks.keys = [] }

let test_unknown_kid_refetches () =
  let url = "https://idp.example.com/rotated/jwks.json" in
  seed_jwks_cache ~url ~age_s:60.0 empty_jwks_doc;
  let fetches = ref 0 in
  let fetch _ =
    incr fetches;
    Ok (Jose.Jwks.of_string rsa_jwks_doc)
  in
  (match
     Test_auth_internal.validate
       ~fetch_jwks:fetch
       (jwks_cfg_for url)
       (bearer (sign_rs256 ()))
   with
   | Ok _ -> ()
   | Error _ -> Windtrap.fail "a key rotated in after the last fetch must be found");
  Windtrap.equal Windtrap.int ~msg:"refetched once" 1 !fetches
;;

let test_unknown_kid_refetch_is_rate_limited () =
  let url = "https://idp.example.com/recent/jwks.json" in
  seed_jwks_cache ~url ~age_s:5.0 empty_jwks_doc;
  let fetches = ref 0 in
  let fetch _ =
    incr fetches;
    Ok (Jose.Jwks.of_string rsa_jwks_doc)
  in
  (match
     Test_auth_internal.validate
       ~fetch_jwks:fetch
       (jwks_cfg_for url)
       (bearer (sign_rs256 ()))
   with
   | Error (`Unauthorized _) -> ()
   | _ -> Windtrap.fail "expected Unauthorized without a refetch");
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
  let validate () =
    match
      Test_auth_internal.validate
        ~fetch_jwks:failing_fetch
        (jwks_cfg_for url)
        (bearer tok)
    with
    | Error (`Server_error _) -> ()
    | _ -> Windtrap.fail "expected Server_error while the IdP is down"
  in
  Eio.Fiber.all [ validate; validate; validate; validate; validate ];
  Windtrap.equal Windtrap.int ~msg:"one fetch for five waiting requests" 1 !fetches
;;

let test_unknown_kid_with_failed_refetch_is_401 () =
  let url = "https://idp.example.com/down-rotated/jwks.json" in
  seed_jwks_cache ~url ~age_s:60.0 empty_jwks_doc;
  match
    Test_auth_internal.validate
      ~fetch_jwks:(fun _ -> Error "connection refused")
      (jwks_cfg_for url)
      (bearer (sign_rs256 ()))
  with
  | Error (`Unauthorized _) -> ()
  | _ -> Windtrap.fail "an unknown kid is a 401 even when the refetch fails"
;;

let () =
  Windtrap.run
    "auth"
    [ Windtrap.group "public" [ Windtrap.test "returns Public principal" test_public ]
    ; Windtrap.group
        "api_key"
        [ Windtrap.test "valid key" test_api_key_valid
        ; Windtrap.test "injected reader" test_api_key_uses_injected_reader
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
        ; Windtrap.test "missing header → 401" test_jwt_missing_header
        ]
    ; Windtrap.group
        "jwks (BUG-053)"
        [ Windtrap.test "non-object payload → 401" test_jwt_payload_not_an_object
        ; Windtrap.test
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
    ]
;;
