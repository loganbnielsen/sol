type jwt_algorithm = [ `HS256 | `RS256 | `ES256 | `ES384 | `ES512 ]

type jwt_key_source =
  | Hs256_secret of string
  | Jwks_static  of string
  | Jwks_url     of string

type jwt_verified_config =
  { issuer     : string
  ; audience   : string
  ; algorithms : jwt_algorithm list
  ; key_source : jwt_key_source
  }

type jwt_verification =
  | Verified_signature_required of jwt_verified_config
  | Unverified_dev_only

type jwt_config =
  { scopes       : string list
  ; verification : jwt_verification
  }

type level =
  [ `Public
  | `Api_key
  | `Jwt of jwt_config
  ]

type principal =
  | Public
  | Service of { key_id : string }
  | User of
      { sub    : string
      ; scopes : string list
      ; claims : Yojson.Safe.t
      }

type context = { principal : principal }

(* ── Internal validation ───────────────────────────────────────────────── *)

type error =
  [ `Unauthorized    of string
  | `Forbidden       of string
  | `Server_error    of string
  ]
