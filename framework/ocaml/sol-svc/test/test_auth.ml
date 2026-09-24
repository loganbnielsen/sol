let () = Mirage_crypto_rng_unix.use_default ()
let headers_of kv = Http.Header.of_list kv
let bearer tok = headers_of [ "authorization", "Bearer " ^ tok ]
let api_key k = headers_of [ "x-api-key", k ]

(* ── Public ─────────────────────────────────────────────────────────── *)

let test_public () =
  match Test_auth_internal.validate `Public (headers_of []) with
  | Ok { principal = Auth.Public } -> ()
  | _ -> Alcotest.fail "expected Public principal"
;;

(* ── Api_key ─────────────────────────────────────────────────────────── *)

let test_api_key_valid () =
  let read_api_key () = Some "secretkey123" in
  match Test_auth_internal.validate ~read_api_key `Api_key (api_key "secretkey123") with
  | Ok { principal = Auth.Service { key_id } } ->
    Alcotest.(check string) "key_id truncated" "secretke" key_id
  | _ -> Alcotest.fail "expected Service principal"
;;

let test_api_key_wrong () =
  let read_api_key () = Some "secretkey123" in
  match Test_auth_internal.validate ~read_api_key `Api_key (api_key "wrongkey") with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"
;;

let test_api_key_missing_header () =
  let read_api_key () = Some "secretkey123" in
  match Test_auth_internal.validate ~read_api_key `Api_key (headers_of []) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"
;;

let test_api_key_without_reader_fails_closed () =
  match Test_auth_internal.validate `Api_key (api_key "secretkey123") with
  | Error (`Server_error _) -> ()
  | _ -> Alcotest.fail "expected Server_error"
;;

let test_api_key_uses_injected_reader () =
  let read_api_key () = Some "secretkey123" in
  match Test_auth_internal.validate ~read_api_key `Api_key (api_key "secretkey123") with
  | Ok { principal = Auth.Service { key_id } } ->
    Alcotest.(check string) "key_id truncated" "secretke" key_id
  | _ -> Alcotest.fail "expected Service principal"
;;

let test_api_key_empty_secret_fails_closed () =
  let read_api_key () = Some "" in
  match Test_auth_internal.validate ~read_api_key `Api_key (api_key "") with
  | Error (`Server_error _) -> ()
  | Ok _ -> Alcotest.fail "empty API key must not authenticate"
  | Error _ -> Alcotest.fail "expected Server_error for empty configured API key"
;;

(* ── JWT: Unverified_dev_only ──────────────────────────────────────────── *)

(* Build a minimal (unverified) JWT payload: header.payload.sig
   We use HS256 header and a simple JSON payload. Signature is fake for v1. *)
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
    Alcotest.(check string) "sub" "user1" sub;
    Alcotest.(check bool) "scopes" true (List.mem "write" scopes)
  | _ -> Alcotest.fail "expected User principal"
;;

let test_jwt_superset_scopes () =
  (* Token has more scopes than required — should pass *)
  let tok = make_jwt ~scopes:[ "read"; "write"; "admin" ] () in
  match Test_auth_internal.validate (jwt_cfg [ "read" ]) (bearer tok) with
  | Ok { principal = Auth.User _ } -> ()
  | _ -> Alcotest.fail "expected User principal"
;;

let test_jwt_missing_scope () =
  let tok = make_jwt ~scopes:[ "read" ] () in
  match Test_auth_internal.validate (jwt_cfg [ "read"; "write" ]) (bearer tok) with
  | Error (`Forbidden msg) ->
    Alcotest.(check bool) "mentions missing scope" true (String.length msg > 0)
  | _ -> Alcotest.fail "expected Forbidden"
;;

let test_jwt_expired () =
  let tok = make_jwt ~exp_offset:(-1.0) () in
  match Test_auth_internal.validate (jwt_cfg []) (bearer tok) with
  | Error (`Unauthorized msg) ->
    Alcotest.(check bool)
      "expired message"
      true
      (let m = String.lowercase_ascii msg in
       String.length m > 0)
  | _ -> Alcotest.fail "expected Unauthorized"
;;

let test_jwt_malformed () =
  match Test_auth_internal.validate (jwt_cfg []) (bearer "not.a.jwt.at.all.extra") with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"
;;

let test_jwt_wrong_bearer_scheme () =
  match
    Test_auth_internal.validate (jwt_cfg []) (headers_of [ "authorization", "Token abc" ])
  with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"
;;

let test_jwt_payload_not_base64 () =
  match Test_auth_internal.validate (jwt_cfg []) (bearer "header.%.signature") with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"
;;

let test_jwt_payload_not_json () =
  match
    Test_auth_internal.validate (jwt_cfg []) (bearer (make_jwt_with_payload "not json"))
  with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"
;;

let test_jwt_missing_header () =
  match Test_auth_internal.validate (jwt_cfg []) (headers_of []) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"
;;

(* ── JWT: Verified_signature_required (JOSE/JWKS) ──────────────────────── *)

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

(* One RSA keypair, generated once, reused by every RS256 test. *)
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
    Alcotest.(check string) "sub" "user1" sub;
    Alcotest.(check bool) "scopes" true (List.mem "write" scopes)
  | _ -> Alcotest.fail "expected User principal"
;;

let test_jwt_verified_rs256_valid () =
  let tok = sign_rs256 ~scopes:[ "read" ] () in
  match
    Test_auth_internal.validate (rs256_verified_cfg ~scopes:[ "read" ] ()) (bearer tok)
  with
  | Ok { principal = Auth.User { sub; _ } } -> Alcotest.(check string) "sub" "user1" sub
  | _ -> Alcotest.fail "expected User principal"
;;

let test_jwt_verified_tampered_signature () =
  let tok = tamper_signature (sign_hs256 ()) in
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer tok) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized (invalid signature)"
;;

let test_jwt_verified_wrong_alg_rejected () =
  (* Correctly-signed HS256 token, but the route only allows RS256. *)
  let tok = sign_hs256 () in
  match
    Test_auth_internal.validate
      (hs256_verified_cfg ~algorithms:[ `RS256 ] ())
      (bearer tok)
  with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized (alg not permitted)"
;;

let test_jwt_verified_wrong_issuer () =
  let tok = sign_hs256 ~iss:"https://someone-else.example.com" () in
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer tok) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized (issuer mismatch)"
;;

let test_jwt_verified_wrong_audience () =
  let tok = sign_hs256 ~aud:"someone-else" () in
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer tok) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized (audience mismatch)"
;;

let test_jwt_verified_expired () =
  let tok = sign_hs256 ~exp_offset:(-1.0) () in
  match Test_auth_internal.validate (hs256_verified_cfg ()) (bearer tok) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized (expired)"
;;

let test_jwt_verified_missing_scope () =
  let tok = sign_hs256 ~scopes:[ "read" ] () in
  match
    Test_auth_internal.validate
      (hs256_verified_cfg ~scopes:[ "read"; "write" ] ())
      (bearer tok)
  with
  | Error (`Forbidden _) -> ()
  | _ -> Alcotest.fail "expected Forbidden (missing scope)"
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
  | Ok _ -> Alcotest.fail "must not fall back to unverified on JWKS fetch failure"
  | Error _ -> Alcotest.fail "expected Server_error (fail closed)"
;;

let test_jwt_verified_jwks_url_without_fetcher_fails_closed () =
  let tok = sign_rs256 () in
  match Test_auth_internal.validate (jwks_url_cfg ()) (bearer tok) with
  | Error (`Server_error _) -> ()
  | Ok _ -> Alcotest.fail "must not fall back to unverified with no fetch_jwks configured"
  | Error _ -> Alcotest.fail "expected Server_error (fail closed)"
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
  | Ok _ -> Alcotest.fail "malformed static JWKS must not authenticate"
  | Error _ -> Alcotest.fail "expected Server_error for malformed static JWKS"
;;

(* ── BUG-053 / FND-0050 ──────────────────────────────────────────────── *)

let test_jwt_payload_not_an_object () =
  match
    Test_auth_internal.validate (jwt_cfg []) (bearer (make_jwt_with_payload "[]"))
  with
  | Error (`Unauthorized _) -> ()
  | Error _ -> Alcotest.fail "expected Unauthorized"
  | Ok _ -> Alcotest.fail "a non-object payload must be rejected"
  | exception e ->
    Alcotest.failf "a non-object payload must be a 401, not %s" (Printexc.to_string e)
;;

(* Each test uses its own URL, so the process-wide cache never carries over. *)
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
    (* Suspends the fiber, as a network fetch does. *)
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
  Alcotest.(check (pair string string)) "both requests verified" ("ok", "ok") (a, b);
  Alcotest.(check int) "one fetch served both" 1 !fetches
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
  (* A set older than the refetch interval but inside the TTL, without the key. *)
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
   | Error _ -> Alcotest.fail "a key rotated in after the last fetch must be found");
  Alcotest.(check int) "refetched once" 1 !fetches
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
   | _ -> Alcotest.fail "expected Unauthorized without a refetch");
  Alcotest.(check int) "no refetch inside the interval" 0 !fetches
;;

let () =
  Alcotest.run
    "auth"
    [ "public", [ Alcotest.test_case "returns Public principal" `Quick test_public ]
    ; ( "api_key"
      , [ Alcotest.test_case "valid key" `Quick test_api_key_valid
        ; Alcotest.test_case "injected reader" `Quick test_api_key_uses_injected_reader
        ; Alcotest.test_case "wrong key → 401" `Quick test_api_key_wrong
        ; Alcotest.test_case "missing header → 401" `Quick test_api_key_missing_header
        ; Alcotest.test_case
            "no reader fails closed"
            `Quick
            test_api_key_without_reader_fails_closed
        ; Alcotest.test_case
            "empty secret fails closed"
            `Quick
            test_api_key_empty_secret_fails_closed
        ] )
    ; ( "jwt_unverified"
      , [ Alcotest.test_case "valid token" `Quick test_jwt_valid
        ; Alcotest.test_case "superset scopes → ok" `Quick test_jwt_superset_scopes
        ; Alcotest.test_case "missing scope → 403" `Quick test_jwt_missing_scope
        ; Alcotest.test_case "expired → 401" `Quick test_jwt_expired
        ; Alcotest.test_case "malformed → 401" `Quick test_jwt_malformed
        ; Alcotest.test_case "wrong bearer → 401" `Quick test_jwt_wrong_bearer_scheme
        ; Alcotest.test_case "bad payload b64 → 401" `Quick test_jwt_payload_not_base64
        ; Alcotest.test_case "bad payload JSON → 401" `Quick test_jwt_payload_not_json
        ; Alcotest.test_case "missing header → 401" `Quick test_jwt_missing_header
        ] )
    ; ( "jwks (BUG-053)"
      , [ Alcotest.test_case
            "non-object payload → 401"
            `Quick
            test_jwt_payload_not_an_object
        ; Alcotest.test_case
            "concurrent cache misses share one fetch"
            `Quick
            test_concurrent_cache_misses_share_one_fetch
        ; Alcotest.test_case "unknown kid refetches" `Quick test_unknown_kid_refetches
        ; Alcotest.test_case
            "unknown kid refetch is rate-limited"
            `Quick
            test_unknown_kid_refetch_is_rate_limited
        ] )
    ; ( "jwt_verified"
      , [ Alcotest.test_case "HS256 valid → ok" `Quick test_jwt_verified_hs256_valid
        ; Alcotest.test_case
            "RS256 valid (JWKS) → ok"
            `Quick
            test_jwt_verified_rs256_valid
        ; Alcotest.test_case
            "tampered signature → 401"
            `Quick
            test_jwt_verified_tampered_signature
        ; Alcotest.test_case
            "alg not in allowlist → 401"
            `Quick
            test_jwt_verified_wrong_alg_rejected
        ; Alcotest.test_case "wrong issuer → 401" `Quick test_jwt_verified_wrong_issuer
        ; Alcotest.test_case
            "wrong audience → 401"
            `Quick
            test_jwt_verified_wrong_audience
        ; Alcotest.test_case "expired → 401" `Quick test_jwt_verified_expired
        ; Alcotest.test_case "missing scope → 403" `Quick test_jwt_verified_missing_scope
        ; Alcotest.test_case
            "JWKS fetch failure fails closed → 500"
            `Quick
            test_jwt_verified_jwks_fetch_failure_fails_closed
        ; Alcotest.test_case
            "Jwks_url with no fetcher fails closed → 500"
            `Quick
            test_jwt_verified_jwks_url_without_fetcher_fails_closed
        ; Alcotest.test_case
            "malformed static JWKS fails closed → 500"
            `Quick
            test_jwt_verified_malformed_static_jwks_fails_closed
        ] )
    ]
;;
