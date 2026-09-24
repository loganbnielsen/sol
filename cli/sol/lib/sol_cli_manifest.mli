type secret_backend =
  | Kubernetes_live
  (** Emit a Kubernetes Secret with real values (live deploy / sol up). *)
  | Kubernetes_placeholder
  (** Emit a redacted Kubernetes Secret with empty stringData (GitOps). *)
  | External_secrets of
      { store_ref : string
      ; store_kind : string
      ; key_prefix : string
      ; refresh_interval : string
      }

val secret_backend_to_string : secret_backend -> string

type primitive =
  | Svc
  | Worker
  | Fn

type service =
  { domain : string
  ; name : string
  ; primitive : primitive
  ; dir : string
  }

(* CODE_LAYER-019: typed workspace facts. A [workload_fact] is produced for
   every recognized Sol primitive directory, even when it is missing a
   Dockerfile, so `sol check` can report that as a finding. Directories that do
   not look like a Sol primitive are returned in [unexpected] instead of being
   silently skipped.
   Tuples are used rather than records so the new facts do not duplicate the
   field labels already used by [service] in this module. *)

(** A [service] plus whether it has a Dockerfile. *)
type workload_fact = service * bool

(** [(domain, name, dir)] for a directory that does not match a Sol workload
    suffix. *)
type unexpected = string * string * string

type workspace_scan =
  { workloads : workload_fact list
  ; unexpected : unexpected list
  }

type discover_error =
  | Missing_app_dir
  | Workspace_error of Sol_cli_workspace.workspace_error

val workload_fact_to_service : workload_fact -> service

(** Scan every workload on disk. Discovery never filters: selection is applied
    once, after discovery, by [Sol_cli_workload_selection] (FEAT-065). *)
val scan_workspace : unit -> (workspace_scan, discover_error) result

val primitive_of_suffix : string -> primitive option
val primitive_label : primitive -> string
val discover_error_to_string : discover_error -> string
val discover_services_result : unit -> (service list, discover_error) result
val discover_services : unit -> service list
val default_cluster_env : (string * string) list
val default_secrets : (string * string) list
val runtime_secret_name : string

(** The per-workload Secret name ([<workload>-secrets]). The convention lives here
    once; the shared runtime Secret is deliberately NOT workload-suffixed, so the
    two names are not derived from each other. *)
val workload_secret_name : string -> string

val config_hash : (string * string) list -> string

(** Bounds a taxonomy label value to Kubernetes' 63-char label-value limit and
    fixes up a trailing non-alphanumeric character left by truncation (or
    present in the original value). Applied to every taxonomy label value
    except [`release`], which is label-safe by construction
    ([Sol_cli_release_id.t]) and is written verbatim so the manifest label can
    never drift from the stored release id -- exposed here since it's a
    reusable safety net, not a guarantee any particular caller already
    provides.
*)
val sanitize_label_value : string -> string

(** Low-level YAML document builders used by
    [Sol_cli_deployment_render.render_spec]. *)
val namespace_doc : ns:string -> string

(** INFRA-025: binds the deploy identity's Kubernetes group to the
    `sol-deploy` ClusterRole inside [ns]. Used by {!Sol_cli_substrate.ensure}
    to scope the deploy identity to application namespaces only. *)
val deploy_role_binding_doc : ns:string -> string

(** DEC-038: the operator's read-only diagnostic RoleBinding for one application
    namespace. Binds the [sol-operator-diagnostics] ClusterRole to the
    [sol:operators] group; grants observation only, never mutation. *)
val operator_role_binding_doc : ns:string -> string

val service_account_doc : ns:string -> name:string -> string

(** AUDIT-080: the voluntary-disruption budget rendered for a
    node-failure-tolerant workload, so a node drain cannot evict every ready
    replica at once. *)
val pdb_doc : ns:string -> name:string -> replicas:int -> string

val configmap_doc
  :  ?extra_env:(string * string) list
  -> ns:string
  -> name:string
  -> unit
  -> string

(** [name] is the *final* Secret name -- this applies no naming convention. Pass
    [runtime_secret_name] for the shared runtime Secret, or
    [workload_secret_name workload] for a workload's own. *)
val secret_doc
  :  ?base_secrets:(string * string) list
  -> ?extra_secrets:(string * string) list
  -> ?redact:bool
  -> ns:string
  -> name:string
  -> unit
  -> string

val external_secret_doc
  :  store_ref:string
  -> store_kind:string
  -> key_prefix:string
  -> refresh_interval:string
  -> secret_keys:string list
  -> ns:string
  -> name:string
  -> string

type workload_shape =
  | Http_service
  | Background_worker
  (** Workload shape determines exposed container ports and health probes.
          [Http_service] exposes app HTTP on 8080 with probes;
          [Background_worker] exposes metrics on 9090; consumer probes are
          rendered when it also consumes Kafka (AUDIT-080). *)

val deployment_doc
  :  ?rollout_strategy:Sol_cli_toml.rollout_strategy
  -> ?extra_labels:(string * string) list
  -> ?secret_keys:string list
  -> ?volumes:Sol_cli_toml.volume list
  -> ?env:string
  -> ?config_hash:string
  -> ?availability:Sol_cli_availability.t
  -> ?consumes_kafka:bool
  -> shape:workload_shape
  -> replicas:int
  -> cpu:string
  -> memory:string
  -> ns:string
  -> name:string
  -> image:string
  -> workspace:string
  -> domain:string
  -> primitive:string
  -> release_id:Sol_cli_release_id.t
  -> unit
  -> string

(** [rollout_doc] renders an Argo Rollout resource instead of a Deployment.
    Requires Argo Rollouts installed in the cluster. [pd] must be [Canary _] or
    [Blue_green]. *)
val rollout_doc
  :  ?extra_labels:(string * string) list
  -> ?secret_keys:string list
  -> ?volumes:Sol_cli_toml.volume list
  -> ?config_hash:string
  -> ?env:string
  -> ?availability:Sol_cli_availability.t
  -> ?consumes_kafka:bool
  -> shape:workload_shape
  -> replicas:int
  -> cpu:string
  -> memory:string
  -> ns:string
  -> name:string
  -> image:string
  -> pd:Sol_cli_toml.progressive_delivery
  -> workspace:string
  -> domain:string
  -> primitive:string
  -> release_id:Sol_cli_release_id.t
  -> unit
  -> string

(** [pvc_docs ~ns ~name volumes] renders one PersistentVolumeClaim per declared
    volume. [storage] is emitted as-is; StorageClass and backup policy are out
    of scope. *)
val pvc_docs : ns:string -> name:string -> Sol_cli_toml.volume list -> string

(** [blue_green_service_docs ~ns ~name] renders two ClusterIP Services
    ([<name>-active] and [<name>-preview]) required by the blue-green strategy.
*)
val blue_green_service_docs : ns:string -> name:string -> string

val service_doc : ns:string -> name:string -> string

val ingress_doc
  :  ?ingress_host:string
  -> ?ingress_path:string
  -> ?cluster_issuer:string
  -> ?tls_secret_name:string
  -> ns:string
  -> name:string
  -> unit
  -> string

val network_policy_doc
  :  ?egress_to:(string * string) list
  -> ?ingress_from:(string * string) list
  -> ns:string
  -> name:string
  -> unit
  -> string

val cronjob_doc
  :  ?secret_keys:string list
  -> ?env:string
  -> ns:string
  -> name:string
  -> image:string
  -> schedule:string
  -> concurrency_policy:string
  -> backoff_limit:int
  -> cpu:string
  -> memory:string
  -> workspace:string
  -> domain:string
  -> release_id:Sol_cli_release_id.t
  -> unit
  -> string

exception Deploy_failed of string

val write_tmp : string -> string

(** INFRA-048: establishes an object with [kubectl create], treating
    "AlreadyExists" as success. This is how a Sol-created namespace is
    established: the deploy identity's bootstrap grant is deliberately
    create-only, so idempotency cannot come from [kubectl apply]'s patch. Shared
    with {!Sol_cli_substrate}. *)
val create_idempotent
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (unit, string) result

(** FEAT-063: applies into the cluster [ctx] names. *)
val apply
  :  ctx:Sol_cli_kube_destination.context
  -> string * string
  -> dry_run:bool
  -> unit

val emit_to_dir : string -> string * string -> ns:string -> name:string -> string
