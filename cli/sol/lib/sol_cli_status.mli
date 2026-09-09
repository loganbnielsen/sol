(* Workspace-level status rollup for 'sol status' (OBS-009). *)

type domain_status = Healthy | Degraded | Not_deployed

val rollup_domain_status : ns_exists:bool -> string option list -> domain_status
(** [rollup_domain_status ~ns_exists diagnoses] aggregates one domain's
    per-service diagnoses (as returned by
    [Sol_cli_rollout_diagnosis.diagnose_service_live] -- [None] means healthy,
    [Some _] means that service's rollout failed) into a single domain-level
    status:
    - [Not_deployed] when the namespace doesn't exist.
    - [Degraded] when the namespace exists and any service is unhealthy.
    - [Healthy] when the namespace exists and every service is healthy. *)

val domain_status_to_string : domain_status -> string
(** Display label. Non-healthy states are upper-cased so they stand out in
    plain-text output without needing ANSI colors. *)

(* Observability reachability (OBS-018). *)

type reachability = Healthy | Unreachable | Not_checked

val reachability_to_string : reachability -> string

val probe_url :
  backend:Sol_cli_observability_url.backend ->
  explicit_url:string option ->
  default_local_url:string ->
  probe_path:string ->
  string option
(** [probe_url ~backend ~explicit_url ~default_local_url ~probe_path] decides
    which URL, if any, is safe to check: [explicit_url] always wins; otherwise
    only [Local]'s hardcoded default is meaningful to guess at -- [None] ("don't
    check") for any other backend. *)

val reachability_of_probe :
  probe_url:string option ->
  is_reachable:(string -> (unit, string) result) ->
  reachability
(** [reachability_of_probe ~probe_url ~is_reachable] classifies the result of
    [probe_url]: [Not_checked] when there's nothing to check, otherwise
    [Healthy]/[Unreachable] per [is_reachable url]. *)

(* OBS-031: distinguishes "no URL configured" from "URL configured but the
   request failed" -- shared message builders for `sol status` and
   `sol logs` so both commands say the same thing for the same failure. *)

type observability_signal = Loki | Prometheus

val not_configured_message :
  signal:observability_signal ->
  backend:Sol_cli_observability_url.backend ->
  string
(** Message for the "no URL configured" case: no
    [--loki-base-url]/[--prometheus-base-url] flag was given and [backend] isn't
    [Local], so there's no default URL to guess at. Explains why, and gives the
    exact `kubectl port-forward` command plus the flag needed to point the CLI
    at a real cluster. No trailing period, like [unreachable_message] -- the
    caller owns the surrounding sentence. *)

val unreachable_message : url:string -> error:string -> string
(** Message for the "URL configured but the request failed" case -- deliberately
    distinct text from [not_configured_message] so a real outage or a wrong URL
    doesn't hide behind wording that looks like the normal unconfigured case. *)

val reachability_line :
  signal:observability_signal ->
  backend:Sol_cli_observability_url.backend ->
  probe_url:string option ->
  is_reachable:(string -> (unit, string) result) ->
  string
(** [reachability_line ~signal ~backend ~probe_url ~is_reachable] renders the
    full message body for one observability signal's status-line entry:
    [not_configured_message] when [probe_url] is [None], ["healthy"] when
    [is_reachable url] succeeds, otherwise [unreachable_message]. [is_reachable]
    is injected (as in [reachability_of_probe] above) so this is directly
    unit-testable without a real curl call -- the I/O stays in [cmd_status.ml].
*)

val service_is_declared : k8s_name:string -> string list -> bool
(** [service_is_declared ~k8s_name declared_k8s_names] is [true] when [k8s_name]
    is one of [declared_k8s_names] -- the pure decision behind `sol status
    <domain>/<service>` rejecting an undeclared service (OBS-022). Discovering
    [declared_k8s_names] itself is a filesystem scan and stays in
    [cmd_status.ml]; this is just the set-membership check, pulled out so it's
    directly testable. *)

val pod_expectation_of_primitive :
  Sol_cli_manifest.primitive -> Sol_cli_rollout_diagnosis.pod_expectation
(** Which health model a declared service's primitive implies: [Fn] is
    [Ephemeral] (CronJob-status diagnosis), [Svc]/[Worker] are [Continuous]
    (live-pod diagnosis). Swapping this mapping would silently reintroduce the
    OBS-024/026 regression (a zero-pod Fn reported as failed), so it's pulled
    out of `cmd_status.ml` to be directly unit-tested rather than left as
    untested glue. *)
