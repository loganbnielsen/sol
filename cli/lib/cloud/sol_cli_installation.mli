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
  | Publisher_identity
  | Delegated_zone

val prerequisite_label : prerequisite -> string
val prerequisites : Sol_cli_provider.t -> prerequisite list
val verdict_label : verdict -> string
val establish : verdict
val unmet : string -> verdict
val unknown : string -> verdict
val unresolved : (prerequisite * verdict) list -> (prerequisite * verdict) list
val all_established : (prerequisite * verdict) list -> (unit, string) result
val summary : (prerequisite * verdict) list -> string

type resolved_configuration =
  { state_bucket : string
  ; state_prefix : string
  ; region : string
  ; lock_table : string option
  ; zone_domain : string option
  ; project_id : string option
  }

val resolved_configuration_to_lines : resolved_configuration -> string list
