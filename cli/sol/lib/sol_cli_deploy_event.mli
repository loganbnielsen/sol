(* Structured Loki release-event line for `sol deploy` (OBS-037). *)

type t = {
  workspace : string;
  env : string;
  domain : string;
  service : string;
  primitive : string;
  release : string;
}

val fields : t -> (string * string) list
(** [fields t] is the field set pushed with the deploy-event log line:
    [event=deploy] plus [t]'s taxonomy fields, matching
    [Sol_cli_manifest_yaml.render_taxonomy_labels]'s label set so a release's
    manifest labels and its deploy-event line agree. *)

val message : t -> string
(** [message t] is the human-readable log line body. *)

(** Decision for where (if anywhere) to push a deploy event, given the resolved
    observability backend and an explicit [--loki-push-url] override:
    - [Explicit url] -- the override was given; use it as-is.
    - [Auto_detect] -- [Local]/[Self_hosted_durable] both run their own
      in-cluster Loki; the caller should probe the live cluster for it (e.g.
      `kubectl get svc/loki -n monitoring`) and, if found, port-forward to reach
      it -- this decision layer stays pure and leaves that I/O to the caller.
    - [Skip reason] -- nothing to push to and why (currently: the [External]
      backend, which has no in-cluster Loki and no configured push URL in
      [Sol_cli_config]). *)
type push_url_decision = Explicit of string | Auto_detect | Skip of string

val resolve_push_url :
  backend:Sol_cli_observability_url.backend ->
  explicit_url:string option ->
  push_url_decision
(** [resolve_push_url ~backend ~explicit_url] decides how to reach Loki for a
    deploy-event push: [explicit_url] always wins; otherwise [Local]/
    [Self_hosted_durable] resolve to [Auto_detect], [External] to [Skip _]. *)
