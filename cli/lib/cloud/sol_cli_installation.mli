type verdict =
  | Established
  | Unmet of string
  | Unknown of string

type prerequisite =
  | State_backend
  | State_lock
  | Provisioning_identity
  | Cluster_access_identity
  | Deploy_identity
  | Operator_identity
  | Delegated_zone

val prerequisite_label : prerequisite -> string
val verdict_label : verdict -> string
val establish : verdict
val unmet : string -> verdict
val unknown : string -> verdict
val unresolved : (prerequisite * verdict) list -> (prerequisite * verdict) list
val all_established : (prerequisite * verdict) list -> (unit, string) result
val summary : (prerequisite * verdict) list -> string

type zone_ownership =
  | Sol_created
  | User_supplied
  | Externally_delegated

val zone_ownership_of_declaration : string option -> (zone_ownership, string) result
val zone_ownership_declaration : zone_ownership -> string

type zone =
  | No_zone
  | Service_zone of
      { domain : string
      ; ownership : zone_ownership
      }

type installation_config =
  { state_bucket : string
  ; state_prefix : string
  ; region : string
  ; lock_table : string option
  ; provisioning_identity : string option
  ; cluster_access_identity : string option
  ; deploy_identity : string option
  ; operator_identity : string option
  ; zone : zone
  ; project_id : string option
  }

val zone_domain : zone -> string option
val owns_the_zone : zone -> bool
val of_target : Sol_cli_config.target -> (installation_config, string) result
val resolved_configuration_to_lines : installation_config -> string list

type observation =
  | Observed of string
  | Absent of string
  | Unobservable of string

type probe =
  | Inspect of
      { prerequisite : prerequisite
      ; argv : string list
      ; classify : observation -> verdict
      }
  | Unavailable of
      { prerequisite : prerequisite
      ; reason : string
      }
  | Unverifiable of
      { prerequisite : prerequisite
      ; reason : string
      }

val probe_prerequisite : probe -> prerequisite
val present_if_output : prerequisite -> string list -> probe

val present_if_output_names
  :  ?present:(string -> bool)
  -> prerequisite
  -> reason:string
  -> string list
  -> probe

val absent : prerequisite -> string -> probe
val unverifiable : prerequisite -> string -> probe

val observe
  :  run:(string list -> observation)
  -> probe list
  -> (prerequisite * verdict) list
