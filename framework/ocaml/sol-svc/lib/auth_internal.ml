open Auth

(* ── Internal validation ───────────────────────────────────────────────── *)

let constant_time_equal s1 s2 =
  let len1 = String.length s1
  and len2 = String.length s2 in
  if len1 <> len2
  then false
  else (
    let res = ref 0 in
    for i = 0 to len1 - 1 do
      res := !res lor (Char.code s1.[i] lxor Char.code s2.[i])
    done;
    !res = 0)
;;

let validate_api_key ~read_api_key headers =
  match Http.Header.get headers "x-api-key" with
  | None -> Error (`Unauthorized "Missing X-Api-Key header")
  | Some provided ->
    (match read_api_key () with
     | None ->
       Error
         (`Server_error "API key not configured (set SOL_API_KEY or SOL_API_KEY_FILE)")
     | Some "" ->
       Error (`Server_error "API key is empty (set SOL_API_KEY or SOL_API_KEY_FILE)")
     | Some _ when provided = "" -> Error (`Unauthorized "Invalid API key")
     | Some expected ->
       if constant_time_equal provided expected
       then (
         let key_id = String.sub provided 0 (min 8 (String.length provided)) in
         Ok { principal = Service { key_id } })
       else Error (`Unauthorized "Invalid API key"))
;;

let base64url_decode s =
  let s =
    String.map
      (function
        | '-' -> '+'
        | '_' -> '/'
        | c -> c)
      s
  in
  let pad =
    match String.length s mod 4 with
    | 2 -> s ^ "=="
    | 3 -> s ^ "="
    | _ -> s
  in
  match Base64.decode pad with
  | Ok s -> Some s
  | Error _ -> None
;;

let token_scopes json =
  match Yojson.Safe.Util.member "scope" json with
  | `String s -> String.split_on_char ' ' s |> List.filter (fun s -> s <> "")
  | `List lst ->
    List.filter_map
      (function
        | `String s -> Some s
        | _ -> None)
      lst
  | _ -> []
;;

let ( let* ) = Result.bind

type jwt_parts =
  { header_b64 : string
  ; payload_b64 : string
  ; signature_b64 : string
  }

let bearer_token headers =
  let* auth =
    Http.Header.get headers "authorization"
    |> Option.to_result ~none:(`Unauthorized "Missing Authorization header")
  in
  let prefix = "Bearer " in
  let plen = String.length prefix in
  if String.length auth < plen || String.sub auth 0 plen <> prefix
  then Error (`Unauthorized "Authorization header must be 'Bearer <token>'")
  else Ok (String.sub auth plen (String.length auth - plen))
;;

let split_jwt token =
  match String.split_on_char '.' token with
  | [ header_b64; payload_b64; signature_b64 ] ->
    Ok { header_b64; payload_b64; signature_b64 }
  | _ -> Error (`Unauthorized "Malformed JWT: expected header.payload.signature")
;;

let decode_jwt_payload parts =
  base64url_decode parts.payload_b64
  |> Option.to_result ~none:(`Unauthorized "Malformed JWT: cannot decode payload")
;;

(* BUG-053: claims are read with [Yojson.Safe.Util.member], which raises on a
   non-object. A token whose payload is, say, a JSON array must be a 401, not an
   exception out of authentication. *)
let require_claims_object = function
  | `Assoc _ as json -> Ok json
  | _ -> Error (`Unauthorized "Malformed JWT: payload is not a JSON object")
;;

let parse_jwt_payload payload_str =
  match Yojson.Safe.from_string payload_str with
  | exception ((Out_of_memory | Stack_overflow | Sys.Break) as exn) -> raise exn
  | exception Yojson.Json_error _ ->
    Error (`Unauthorized "Malformed JWT: payload is not valid JSON")
  | json -> require_claims_object json
;;

let jwt_expired ~now json =
  match Yojson.Safe.Util.member "exp" json with
  | `Int n -> float_of_int n < now
  | `Float f -> f < now
  | _ -> false
;;

let check_jwt_expiry json =
  if jwt_expired ~now:(Unix.gettimeofday ()) json
  then Error (`Unauthorized "JWT expired")
  else Ok ()
;;

let validate_required_scopes ~required ~actual =
  match List.filter (fun scope -> not (List.mem scope actual)) required with
  | [] -> Ok ()
  | scope :: _ -> Error (`Forbidden ("Missing required scope: " ^ scope))
;;

let token_sub json =
  match Yojson.Safe.Util.member "sub" json with
  | `String s -> s
  | _ -> ""
;;

let validate_unverified_jwt config headers =
  let* token = bearer_token headers in
  let* parts = split_jwt token in
  let* payload_str = decode_jwt_payload parts in
  let* json = parse_jwt_payload payload_str in
  let* () = check_jwt_expiry json in
  let scopes = token_scopes json in
  let* () = validate_required_scopes ~required:config.scopes ~actual:scopes in
  Ok { principal = User { sub = token_sub json; scopes; claims = json } }
;;

(* ── Verified JWT (JOSE/JWKS) ──────────────────────────────────────────── *)

type jwks_cache_entry =
  { url : string
  ; fetched_at : float
  ; jwks : Jose.Jwks.t
  }

let jwks_cache : jwks_cache_entry option Atomic.t = Atomic.make None

(* BUG-053 / FND-0050: an Eio mutex, not [Stdlib.Mutex]. The fetch it guards
   suspends the fiber; another request fiber on the same domain that took a
   [Stdlib.Mutex] held by its own thread raised [Sys_error "Resource deadlock
   avoided"], which surfaced as an empty reply. An Eio mutex suspends the second
   fiber instead, and it then finds the refreshed cache (single flight).
   [use_ro], not [use_rw]: a cancelled or failed fetch must release the mutex,
   not poison it for every later request. *)
let jwks_refresh_mutex = Eio.Mutex.create ()
let jwks_ttl_s = 300.0
(* ponytail: fixed rotation window; make configurable if a real IdP needs faster/slower *)

(* A token signed with a key the IdP has just rotated in names a [kid] the cached
   set lacks. Refetch for it, but at most once per this interval, so tokens with
   made-up [kid]s cannot drive a fetch per request. *)
let jwks_unknown_kid_refetch_interval_s = 30.0

(* A failed fetch is remembered for this long and returned to every request that
   would otherwise fetch again: without it, requests queued behind the mutex each
   ran their own fetch in turn during an IdP outage, so the Nth waited about N
   request timeouts. *)
let jwks_failure_backoff_s = 5.0
let jwks_last_failure : (string * float * string) option Atomic.t = Atomic.make None

(* Real transport for [Jwks_url]. [Service.Make.run] builds this once, closing
   over [env], and passes it into [validate] as the injected [fetch_jwks]
   capability — [validate] itself stays Eio-free. *)
let fetch_jwks_over_https ~env url =
  match
    Https_eio.request
      ~net:env#net
      ~clock:env#clock
      ~timeout:10.0
      ~meth:`GET
      ~url
      ~headers:[ "Accept", "application/json" ]
      ()
  with
  | Error e -> Error (Https_eio.request_error_to_string e)
  | Ok (status, _) when status <> 200 ->
    Error (Printf.sprintf "JWKS fetch failed: HTTP %d" status)
  | Ok (_, body) ->
    (try Ok (Jose.Jwks.of_string body) with
     | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error ("JWKS parse failed: " ^ Printexc.to_string exn))
;;

(* [~max_age_s] is how old a cached set may be and still be used: the TTL
   normally, and the refetch interval when the caller is looking for an unknown
   [kid]. *)
let get_jwks ?(max_age_s = jwks_ttl_s) ~fetch_jwks url =
  let usable entry =
    entry.url = url && Unix.gettimeofday () -. entry.fetched_at < max_age_s
  in
  match Atomic.get jwks_cache with
  | Some entry when usable entry -> Ok entry.jwks
  | _ ->
    Eio.Mutex.use_ro jwks_refresh_mutex (fun () ->
      (* Another fiber may have refreshed -- or failed to -- while this one
         waited. *)
      match Atomic.get jwks_cache, Atomic.get jwks_last_failure with
      | Some entry, _ when usable entry -> Ok entry.jwks
      | _, Some (u, at, msg)
        when u = url && Unix.gettimeofday () -. at < jwks_failure_backoff_s -> Error msg
      | _ ->
        (match fetch_jwks url with
         | Ok jwks ->
           Atomic.set jwks_cache (Some { url; fetched_at = Unix.gettimeofday (); jwks });
           Atomic.set jwks_last_failure None;
           Ok jwks
         | Error msg as e ->
           Atomic.set jwks_last_failure (Some (url, Unix.gettimeofday (), msg));
           e))
;;

let now_ptime () =
  match Ptime.of_float_s (Unix.gettimeofday ()) with
  | Some t -> t
  | None -> Ptime.epoch
;;

(* [Jose.Jwk.t] is a GADT, so a function can't return "the jwk" across
   branches at one monomorphic type — verify inline in each branch instead. *)
let verify_with_key_source ?fetch_jwks ~kid parsed key_source =
  let with_jwk jwk =
    match Jose.Jwt.validate ~jwk ~now:(now_ptime ()) parsed with
    | Ok t -> Ok t
    | Error `Expired -> Error (`Unauthorized "JWT expired")
    | Error `Invalid_signature -> Error (`Unauthorized "JWT signature invalid")
    | Error (`Msg m) -> Error (`Unauthorized ("JWT invalid: " ^ m))
  in
  let jwks_lookup ?refetch jwks =
    match kid with
    | None -> Error (`Unauthorized "JWT missing kid")
    | Some kid ->
      (match Jose.Jwks.find_key jwks kid with
       | Some jwk -> with_jwk jwk
       | None ->
         let not_found = Error (`Unauthorized "JWT key id not found in JWKS") in
         (match refetch with
          | None -> not_found
          | Some refetch ->
            (* The cached set is authoritative within its TTL; the refetch is
               best effort. If it fails, the key is simply not known: 401, not
               a 500 an attacker could trigger with made-up kids. *)
            (match refetch () with
             | Error _ -> not_found
             | Ok jwks ->
               (match Jose.Jwks.find_key jwks kid with
                | Some jwk -> with_jwk jwk
                | None -> not_found))))
  in
  match key_source with
  | Hs256_secret secret -> with_jwk (Jose.Jwk.make_oct secret)
  | Jwks_static doc ->
    (try jwks_lookup (Jose.Jwks.of_string doc) with
     | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (`Server_error ("JWKS parse failed: " ^ Printexc.to_string exn)))
  | Jwks_url url ->
    (match fetch_jwks with
     | None ->
       Error (`Server_error "Jwks_url configured but no JWKS fetcher was provided")
     | Some fetch_jwks ->
       (match get_jwks ~fetch_jwks url with
        | Error msg -> Error (`Server_error ("JWKS fetch failed: " ^ msg))
        | Ok jwks ->
          jwks_lookup
            ~refetch:(fun () ->
              get_jwks ~max_age_s:jwks_unknown_kid_refetch_interval_s ~fetch_jwks url)
            jwks))
;;

let jwt_alg_allowed algorithms (alg : Jose.Jwa.alg) =
  List.exists
    (fun a ->
       match (a : jwt_algorithm), alg with
       | `HS256, `HS256 -> true
       | `RS256, `RS256 -> true
       | `ES256, `ES256 -> true
       | `ES384, `ES384 -> true
       | `ES512, `ES512 -> true
       | _ -> false)
    algorithms
;;

let claim_strings json name =
  match Yojson.Safe.Util.member name json with
  | `String s -> [ s ]
  | `List lst ->
    List.filter_map
      (function
        | `String s -> Some s
        | _ -> None)
      lst
  | _ -> []
;;

let check_issuer ~issuer json =
  match claim_strings json "iss" with
  | [ iss ] when iss = issuer -> Ok ()
  | _ -> Error (`Unauthorized "JWT issuer mismatch")
;;

let check_audience ~audience json =
  if List.mem audience (claim_strings json "aud")
  then Ok ()
  else Error (`Unauthorized "JWT audience mismatch")
;;

let validate_verified_jwt ?fetch_jwks vconfig ~scopes headers =
  let* token = bearer_token headers in
  let* parsed =
    match Jose.Jwt.unsafe_of_string token with
    | Ok t -> Ok t
    | Error _ -> Error (`Unauthorized "Malformed JWT")
  in
  let alg = parsed.Jose.Jwt.header.Jose.Header.alg in
  let* () =
    if jwt_alg_allowed vconfig.algorithms alg
    then Ok ()
    else Error (`Unauthorized "JWT alg not permitted")
  in
  let kid = parsed.Jose.Jwt.header.Jose.Header.kid in
  let* verified = verify_with_key_source ?fetch_jwks ~kid parsed vconfig.key_source in
  let* json = require_claims_object verified.Jose.Jwt.payload in
  let* () = check_issuer ~issuer:vconfig.issuer json in
  let* () = check_audience ~audience:vconfig.audience json in
  let token_scopes = token_scopes json in
  let* () = validate_required_scopes ~required:scopes ~actual:token_scopes in
  Ok { principal = User { sub = token_sub json; scopes = token_scopes; claims = json } }
;;

let validate_jwt ?fetch_jwks config headers =
  match config.verification with
  | Verified_signature_required vconfig ->
    validate_verified_jwt ?fetch_jwks vconfig ~scopes:config.scopes headers
  | Unverified_dev_only -> validate_unverified_jwt config headers
;;

let validate ?(read_api_key = Fun.const None) ?fetch_jwks level headers =
  match level with
  | `Public -> Ok { principal = Public }
  | `Api_key -> validate_api_key ~read_api_key headers
  | `Jwt cfg -> validate_jwt ?fetch_jwks cfg headers
;;
