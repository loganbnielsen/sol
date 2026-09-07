type secret_backend =
  | Kubernetes_live         (** Emit a Kubernetes Secret with real values (live deploy / sol up). *)
  | Kubernetes_placeholder  (** Emit a redacted Kubernetes Secret with empty stringData (GitOps). *)
  | External_secrets of {
      store_ref        : string;
      store_kind       : string;
      key_prefix       : string;
      refresh_interval : string;
    }

val secret_backend_to_string : secret_backend -> string

type primitive = Svc | Worker | Fn

type service = {
  domain : string;
  name   : string;
  primitive : primitive;
  dir    : string;
}

val primitive_of_suffix : string -> primitive option
val primitive_label : primitive -> string
val discover_services : filter_path:string option -> service list
val extract_schedule  : dir:string -> name:string -> string

val default_cluster_env : (string * string) list
val default_secrets     : (string * string) list
val runtime_secret_name : string
val config_hash : (string * string) list -> string

(** Bounds a taxonomy label value to Kubernetes' 63-char label-value limit
    and fixes up a trailing non-alphanumeric character left by truncation
    (or present in the original value). Applied uniformly to every
    taxonomy label value rendered by [render_taxonomy_labels] -- exposed
    here since it's a reusable safety net, not a guarantee any particular
    caller already provides. *)
val sanitize_label_value : string -> string

(** Low-level YAML document builders used by
    [Sol_cli_deployment_render.render_spec]. *)
val namespace_doc       : ns:string -> string
val service_account_doc : ns:string -> name:string -> string
val configmap_doc       : ?extra_env:(string * string) list -> ns:string -> name:string -> unit -> string
val secret_doc          : ?base_secrets:(string * string) list -> ?extra_secrets:(string * string) list -> ?redact:bool -> ns:string -> name:string -> unit -> string
val external_secret_doc : store_ref:string -> store_kind:string -> key_prefix:string -> refresh_interval:string -> secret_keys:string list -> ns:string -> name:string -> string
type workload_shape = Http_service | Background_worker
(** Workload shape determines exposed container ports and health probes.
    [Http_service] exposes app HTTP on 8080 with probes; [Background_worker]
    exposes metrics on 9090 without probes. *)

val deployment_doc     : ?rollout_strategy:Sol_cli_toml.rollout_strategy -> ?extra_labels:(string * string) list -> ?secret_keys:string list -> ?env:string -> ?config_hash:string -> shape:workload_shape -> replicas:int -> cpu:string -> memory:string -> ns:string -> name:string -> image:string -> workspace:string -> domain:string -> primitive:string -> unit -> string

(** [rollout_doc] renders an Argo Rollout resource instead of a Deployment.
    Requires Argo Rollouts installed in the cluster.
    [pd] must be [Canary _] or [Blue_green]. *)
val rollout_doc : ?extra_labels:(string * string) list -> ?secret_keys:string list -> ?config_hash:string -> ?env:string -> shape:workload_shape -> replicas:int -> cpu:string -> memory:string -> ns:string -> name:string -> image:string -> pd:Sol_cli_toml.progressive_delivery -> workspace:string -> domain:string -> primitive:string -> unit -> string

(** [blue_green_service_docs ~ns ~name] renders two ClusterIP Services
    ([<name>-active] and [<name>-preview]) required by the blue-green strategy. *)
val blue_green_service_docs : ns:string -> name:string -> string

val service_doc        : ns:string -> name:string -> string
val ingress_doc        : ?ingress_host:string -> ?ingress_path:string -> ns:string -> name:string -> unit -> string
val network_policy_doc : ns:string -> name:string -> string
val cronjob_doc        : ?secret_keys:string list -> ?env:string -> ns:string -> name:string -> image:string -> schedule:string -> workspace:string -> domain:string -> unit -> string

exception Deploy_failed of string

val write_tmp : string -> string
val apply     : string * string -> dry_run:bool -> unit
val emit_to_dir : string -> string * string -> ns:string -> name:string -> string
