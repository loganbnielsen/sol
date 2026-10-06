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

(** DEC-063: Sol-to-Sol workload identity. [callers] maps a service-account
    subject ("<namespace>:<serviceaccount>") to the caller's Sol unit;
    [trusted_issuers] maps an accepted issuer to its JWKS URL. *)
type workload_identity_config =
  { audience : string
  ; callers : (string * string) list
  ; trusted_issuers : (string * string) list
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

val constant_time_equal : string -> string -> bool

module For_testing : sig
  val constant_time_equal : string -> string -> bool
  val reset_jwks_cache : unit -> unit
  val seed_stale_jwks_cache : url:string -> age_s:float -> jwks:string -> unit
end
