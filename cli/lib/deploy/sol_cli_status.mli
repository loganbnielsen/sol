type domain_status =
  | Healthy
  | Degraded
  | Unknown of string
  | Not_deployed

type namespace_presence =
  | Ns_present
  | Ns_absent
  | Ns_unreadable of string

val rollup_domain_status
  :  ns_presence:namespace_presence
  -> Sol_cli_rollout_diagnosis.diagnosis list
  -> domain_status

val first_line : string -> string
val domain_status_to_string : domain_status -> string

type reachability =
  | Healthy
  | Unreachable of string
  | Not_checked

val reachability_to_string : reachability -> string

val probe_url
  :  backend:Sol_cli_observability_url.backend
  -> explicit_url:string option
  -> default_local_url:string
  -> probe_path:string
  -> string option

val reachability_of_probe
  :  probe_url:string option
  -> is_reachable:(string -> (unit, string) result)
  -> reachability

type observability_signal =
  | Loki
  | Prometheus

val not_configured_message
  :  signal:observability_signal
  -> backend:Sol_cli_observability_url.backend
  -> string

val unreachable_message : url:string -> error:string -> string

val reachability_line
  :  signal:observability_signal
  -> backend:Sol_cli_observability_url.backend
  -> probe_url:string option
  -> is_reachable:(string -> (unit, string) result)
  -> string

val service_is_declared : k8s_name:string -> string list -> bool

val pod_expectation_of_primitive
  :  Sol_cli_manifest.primitive
  -> Sol_cli_rollout_diagnosis.pod_expectation
