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
    [trusted_issuer] is the target-established Kubernetes issuer. *)
type workload_identity_config =
  { audience : string
  ; callers : (string * string) list
  ; trusted_issuer : string
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

type key_request =
  { issuer : string
  ; key_id : string option
  }

type pending_workload_auth

(** Decode the CLI-projected [unit=namespace:serviceaccount] caller set.
    Invalid entries are ignored, which can only narrow authorization. *)
val callers_of_projection : string -> (string * string) list

val begin_workload_auth
  :  workload_identity_config
  -> authorization:string option
  -> (key_request * pending_workload_auth, error) result

val finish_workload_auth
  :  pending_workload_auth
  -> jwks:Jose.Jwks.t
  -> now:float
  -> (context, error) result

val constant_time_equal : string -> string -> bool

module For_testing : sig
  val constant_time_equal : string -> string -> bool
end
