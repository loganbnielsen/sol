(* Structured Loki release-event line for `sol deploy` (OBS-037). *)

(** A domain object, not the serialized form: both identities stay typed, and
    [fields]/[message] (plus the stream labels the pusher builds) are the
    serialization edge — TYPE_AUDIT-078. *)
type t =
  { workspace : string
  ; env : string
  ; domain : string
  ; service : string
  ; primitive : string
  ; release_id : Sol_cli_release_id.t
  ; deployment_id : Sol_cli_deployment_id.t
    (** FEAT-070: the id of the deployment event this marker describes. It is a
        logfmt *field*, deliberately not a Loki stream label — it varies per
        invocation, and promoting it to a label would put unbounded cardinality
        into Loki's index. It exists so a Grafana timeline can join the marker
        to the authoritative [sol-deployment-<id>] record by id. *)
  }

(** [fields t] is the field set pushed with the deploy-event log line:
    [event=deploy] plus [t]'s taxonomy fields, matching
    [Sol_cli_manifest_yaml.render_taxonomy_labels]'s label set so a release's
    manifest labels and its deploy-event line agree, plus [deployment_id] as the
    FEAT-070 join key. *)
val fields : t -> (string * string) list

(** [message t] is the human-readable log line body. *)
val message : t -> string

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
type push_url_decision =
  | Explicit of string
  | Auto_detect
  | Skip of string

(** [resolve_push_url ~backend ~explicit_url] decides how to reach Loki for a
    deploy-event push: [explicit_url] always wins; otherwise [Local]/
    [Self_hosted_durable] resolve to [Auto_detect], [External] to [Skip _]. *)
val resolve_push_url
  :  backend:Sol_cli_observability_url.backend
  -> explicit_url:string option
  -> push_url_decision
