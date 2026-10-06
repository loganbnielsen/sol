type jwt_algorithm =
  [ `HS256
  | `RS256
  | `ES256
  | `ES384
  | `ES512
  ]

type jwt_key_source =
  | Hs256_secret of string
  | Jwks_static of string
  | Jwks_url of string

type jwt_verified_config =
  { issuer : string
  ; audience : string
  ; algorithms : jwt_algorithm list
  ; key_source : jwt_key_source
  }

type jwt_verification =
  | Verified_signature_required of jwt_verified_config
  | Unverified_dev_only

type jwt_config =
  { scopes : string list
  ; verification : jwt_verification
  }

(* DEC-063: a Sol-to-Sol call authenticates with the caller's projected
   ServiceAccount token. The callee checks the token against a trusted issuer,
   maps the subject to a caller unit, and requires that unit in [callers]. The
   trust root is an explicit (issuer, JWKS URL) set; issuing discovery is a
   separate concern. *)
type workload_identity_config =
  { audience : string
  ; callers : (string * string) list
    (* service account "<namespace>:<serviceaccount>" -> caller unit *)
  ; trusted_issuers : (string * string) list (* issuer -> JWKS URL *)
  }

type level =
  [ `Public
  | `Api_key
  | `Jwt of jwt_config
  | `Workload_identity
  ]

type principal =
  | Public
  | Service of { key_id : string }
  | User of
      { sub : string
      ; scopes : string list
      ; claims : Yojson.Safe.t
      }
  | Unit of
      { unit : string
      ; service_account : string
      }

type context = { principal : principal }

type error =
  [ `Unauthorized of string
  | `Forbidden of string
  | `Server_error of string
  ]

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

module For_testing = struct
  let constant_time_equal = constant_time_equal
  let reset_jwks_cache () = Auth_cache.clear ()

  let seed_stale_jwks_cache ~url ~age_s ~jwks =
    Auth_cache.replace
      { Auth_cache.url
      ; fetched_at = Unix.gettimeofday () -. age_s
      ; jwks = Jose.Jwks.of_string jwks
      }
  ;;
end
