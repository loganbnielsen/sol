type deployment_mode = Local | Customer_cloud | Sol_hosted

type env_config = {
  name : string;
  mode : deployment_mode;
  registry : string;
  image_tag : string;
  env : string option;
      (** Resolved deployment environment (e.g. ["dev"], ["prod"]) from a
          [sol deploy <env>/<provider>/<region>] target. [None] when no target
          was resolved (e.g. [sol up], which is local-only and has no target
          concept). Threaded into generated manifest labels alongside
          [workspace]/[domain]/[service]/[primitive]/[release] — see
          [docs/architecture/observability-design.md]'s Identity table. *)
  region : string option;
  base_domain : string option;
  secret_backend : Sol_cli_manifest.secret_backend;
}

type primitive = Svc | Worker | Fn

type effective_rollout_strategy =
  | Effective_canary
  | Effective_blue_green
  | Effective_recreate
  | Effective_rolling_update

type k8s_name = Sol_cli_kubernetes_name.k8s_name
type namespace = Sol_cli_kubernetes_name.namespace

type service_spec = {
  domain : string;
  source_name : string;
  k8s_name : k8s_name;
  namespace : namespace;
  primitive : primitive;
  source_dir : string;
  image : string;
  config : (string * string) list;
  secrets : (string * string) list;
  volumes : Sol_cli_toml.volume list;
  schedule : string option;
  replicas : int;
  cpu : Sol_cli_toml.cpu_quantity;
  memory : Sol_cli_toml.memory_quantity;
  rollout_strategy : Sol_cli_toml.rollout_strategy option;
  ingress_host : Sol_cli_toml.hostname option;
  ingress_path : Sol_cli_toml.ingress_path option;
  extra_labels : (string * string) list;
  progressive_delivery : Sol_cli_toml.progressive_delivery option;
}

type t = {
  workspace : string;
  environment : env_config;
  services : service_spec list;
  topics : Sol_cli_plan_ids.Topic_name.t list;
  migrations : Sol_cli_plan_ids.Migration_file.t list;
  schema_subjects : Sol_cli_plan_ids.Schema_subject.t list;
  consumer_groups : Sol_cli_plan_ids.Consumer_group.t list;
}

type plan_error =
  | Toml_error of Sol_cli_toml.parse_error
  | Invalid_kubernetes_name of {
      field : string;
      value : string;
      message : string;
    }

val discover_topics : unit -> Sol_cli_plan_ids.Topic_name.t list
(** Scan [events/] subdirectories for [sol.toml] files with topic arrays.
    Returns validated {!Sol_cli_plan_ids.Topic_name.t} values, sorted and
    deduplicated. Invalid names are skipped with a warning. Returns [[]] when
    the [events/] directory does not exist. *)

val discover_migrations : unit -> Sol_cli_plan_ids.Migration_file.t list
(** Scan [db/migrations/*.sql] in the current directory and return validated
    {!Sol_cli_plan_ids.Migration_file.t} values, sorted by filename. Returns
    [[]] when [db/migrations/] does not exist. *)

val discover_schema_subjects : unit -> Sol_cli_plan_ids.Schema_subject.t list
(** Scan [events/<domain>/*.ml] for event contract files and derive schema
    subject names as ["<domain>.<EventName>"]. Top-level [events/<event>.ml]
    files are returned without a domain prefix. Returns validated
    {!Sol_cli_plan_ids.Schema_subject.t} values, sorted and deduplicated.
    Returns [[]] when the [events/] directory does not exist. *)

val derive_consumer_groups :
  string -> service_spec list -> Sol_cli_plan_ids.Consumer_group.t list
(** [derive_consumer_groups workspace services] returns validated
    {!Sol_cli_plan_ids.Consumer_group.t} values for all [Worker] entries in
    [services], sorted and deduplicated. Convention:
    ["<workspace>.<domain>.<worker_name>"]. *)

val mode_to_string : deployment_mode -> string
val primitive_to_string : primitive -> string

val effective_rollout_strategy : service_spec -> effective_rollout_strategy
(** Resolve the deployment strategy that applies after progressive delivery
    settings have taken precedence over Deployment rollout settings. *)

val effective_rollout_strategy_to_string : effective_rollout_strategy -> string
(** Render an [effective_rollout_strategy] for deployment plan JSON and
    summaries. *)

val to_json : t -> Yojson.Safe.t
(** Serialize a deployment plan to JSON (experimental format — schema not
    frozen). Config values are included; secret keys are included but secret
    values are omitted. *)

val pp_summary : Format.formatter -> t -> unit
(** Print a human-readable deployment plan summary. *)

val plan_error_to_string : plan_error -> string
(** Render a deployment-plan construction error for CLI output. *)

val k8s_name_result : string -> (k8s_name, plan_error) result
(** Normalize and validate a service source name as a Kubernetes DNS label. *)

val k8s_name_to_string : k8s_name -> string

val namespace_of_exn : workspace:string -> domain:string -> namespace
(** [namespace_of_exn ~workspace ~domain] returns a validated namespace for
    ["<workspace>-<domain>"]. Raises [Failure] if validation fails. *)

val namespace_result :
  workspace:string -> domain:string -> (namespace, plan_error) result
(** Normalize workspace/domain into a namespace and validate it as a Kubernetes
    DNS label. *)

val namespace_to_string : namespace -> string

val image_ref :
  registry:string ->
  workspace:string ->
  k8s_name:k8s_name ->
  tag:string ->
  string
(** [image_ref ~registry ~workspace ~k8s_name ~tag] returns
    ["<registry>/<workspace>/<k8s_name>:<tag>"]. *)

val of_services :
  workspace:string ->
  env:env_config ->
  ?resolved_config:Sol_cli_config.t ->
  Sol_cli_manifest.service list ->
  t
(** Compatibility wrapper around [of_services_result]. Raises [Failure] if a
    service [sol.toml] cannot be parsed or validated. *)

val of_services_result :
  workspace:string ->
  env:env_config ->
  ?resolved_config:Sol_cli_config.t ->
  Sol_cli_manifest.service list ->
  (t, plan_error) result
(** Build a deployment plan from a discovered service list and an environment
    config. Returns a typed error when a Kubernetes artifact name is invalid or
    a service [sol.toml] cannot be parsed or validated.

    [resolved_config], when given (the [sol deploy]/target-resolved path;
    [sol up] never has one), overrides a service's [sol.toml] [replicas] with
    its [sol.yml] entry's [scale_max] (falling back to [scale_min]) when a
    service of the same name sets either. A service with no matching [sol.yml]
    entry, or no [resolved_config] at all, keeps [sol.toml]'s [replicas]
    unchanged. *)
