(* Workspace-level status rollup for 'sol status' (OBS-009). Pure
   aggregation of diagnosis OBS-001 already computes -- no new diagnosis
   logic here. *)

type domain_status =
  | Healthy
  | Degraded
  | Not_deployed

let rollup_domain_status ~ns_exists (diagnoses : string option list) =
  if not ns_exists
  then Not_deployed
  else if List.exists (fun d -> d <> None) diagnoses
  then Degraded
  else Healthy
;;

let domain_status_to_string = function
  | Healthy -> "healthy"
  | Degraded -> "DEGRADED"
  | Not_deployed -> "NOT DEPLOYED"
;;

(* Observability reachability (OBS-018). Split into a pure decision
   (which URL, if any, to probe) and a pure classification (given whether
   that URL answered), so both are testable without a real curl call --
   the actual I/O stays in cmd_status.ml. *)

type reachability =
  | Healthy
  | Unreachable
  | Not_checked

let reachability_to_string = function
  | Healthy -> "healthy"
  | Unreachable -> "unreachable"
  | Not_checked -> "not checked"
;;

(** [probe_url ~backend ~explicit_url ~default_local_url ~probe_path] decides
    which URL, if any, is safe to check:
    - [explicit_url], when given, always wins.
    - Otherwise, only the [Local] backend's hardcoded default is meaningful to
      guess at -- [Self_hosted_durable]/[External] have no equivalent default
      Loki/Prometheus URL shape, so [None] ("don't check") rather than a
      misleading guess. *)
let probe_url ~backend ~explicit_url ~default_local_url ~probe_path =
  match explicit_url with
  | Some base -> Some (base ^ probe_path)
  | None ->
    (match (backend : Sol_cli_observability_url.backend) with
     | Local -> Some (default_local_url ^ probe_path)
     | Self_hosted_durable | External -> None)
;;

(** [reachability_of_probe ~probe_url ~is_reachable] classifies the result of
    [probe_url] (from [probe_url] above, or a resolved Grafana URL for the
    dashboard line): [Not_checked] when there's no URL to check, otherwise
    [Healthy]/[Unreachable] per [is_reachable url]. *)
let reachability_of_probe ~probe_url ~is_reachable =
  match probe_url with
  | None -> Not_checked
  | Some url ->
    (match is_reachable url with
     | Ok () -> Healthy
     | Error _ -> Unreachable)
;;

(* OBS-031: `sol logs`/`sol status` used to collapse two operationally
   different cases into the same "not checked" text for
   [Self_hosted_durable]/[External] targets -- no URL configured at all
   (nothing to check) vs. a configured URL whose request failed (a real
   outage or a wrong URL). These two builders keep that distinction
   explicit and are shared by both commands so the wording -- and the
   port-forward command/flag pairing -- stays in exactly one place. *)

type observability_signal =
  | Loki
  | Prometheus

let signal_label = function
  | Loki -> "Loki"
  | Prometheus -> "Prometheus"
;;

let signal_flag = function
  | Loki -> "--loki-base-url"
  | Prometheus -> "--prometheus-base-url"
;;

(* Matches cli/platform/infra/base/main.tf's monitoring namespace and the
   loki/prometheus-community chart service names (also mirrored by
   `sol dev up`'s local port-forwards in cmd_local.ml). *)
let signal_port_forward = function
  | Loki -> "kubectl port-forward -n monitoring svc/loki 3100:3100"
  | Prometheus -> "kubectl port-forward -n monitoring svc/prometheus-server 9090:80"
;;

(** Message for the "no URL configured" case: no [--loki-base-url]/
    [--prometheus-base-url] flag was given and [backend] isn't [Local], so
    there's no default URL to guess at. States why, and exactly what to run to
    point the CLI at a real cluster. No trailing period -- like
    [unreachable_message] below, callers own the surrounding sentence. *)
let not_configured_message ~signal ~backend =
  Printf.sprintf
    "not checked: %s has no default %s URL. Run '%s', then pass %s <url>"
    (Sol_cli_observability_url.backend_to_string backend)
    (signal_label signal)
    (signal_port_forward signal)
    (signal_flag signal)
;;

(** Message for the "URL configured but the request failed" case -- deliberately
    distinct text from [not_configured_message] so a real outage or a wrong URL
    doesn't hide behind wording that looks like the normal unconfigured case. *)
let unreachable_message ~url ~error = Printf.sprintf "couldn't reach %s: %s" url error

(** [reachability_line ~signal ~backend ~probe_url ~is_reachable] renders the
    full message body for one observability signal's status-line entry:
    [not_configured_message] when [probe_url] is [None], ["healthy"] when
    [is_reachable url] succeeds, otherwise [unreachable_message]. [is_reachable]
    is injected (as in [reachability_of_probe] above) so this is directly
    unit-testable without a real curl call -- the I/O stays in cmd_status.ml. *)
let reachability_line ~signal ~backend ~probe_url ~is_reachable =
  match probe_url with
  | None -> not_configured_message ~signal ~backend
  | Some url ->
    (match is_reachable url with
     | Ok () -> "healthy"
     | Error error -> unreachable_message ~url ~error)
;;

(* Service-existence decision (OBS-022/024). Pulled out of cmd_status.ml's
   inline check so it's directly unit-tested -- discovering the declared
   k8s names themselves still requires a filesystem scan
   (Sol_cli_manifest.discover_services), so that part stays in
   cmd_status.ml; this is just the pure "is it in the set" decision. *)
let service_is_declared ~k8s_name declared_k8s_names =
  List.mem k8s_name declared_k8s_names
;;

let pod_expectation_of_primitive
  : Sol_cli_manifest.primitive -> Sol_cli_rollout_diagnosis.pod_expectation
  = function
  | Fn -> Ephemeral
  | Svc | Worker -> Continuous
;;
