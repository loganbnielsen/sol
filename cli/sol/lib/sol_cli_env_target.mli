(** Sol_cli_env_target — typed boundary between workspace intent and
    environment-owned substrate inputs.

    Each constructor carries exactly the fields required by that deployment
    mode; impossible states (e.g. a customer cluster deployment with no
    registry) cannot be constructed. *)

type t =
  | Local of { image_tag : string; cluster_registry : string }
  | Customer_direct of { image_tag : string; registry : string }
  | Customer_gitops of { image_tag : string; registry : string }
  | Sol_hosted of { image_tag : string; registry : string }

(** {2 Constructors} *)

val local_defaults : image_tag:string -> t
(** [local_defaults ~image_tag] returns a [Local] target with
    [cluster_registry = "sol-registry:5000"]. *)

val customer_cloud_defaults :
  registry:string ->
  image_tag:string ->
  emit_to:string option ->
  unit ->
  (t, string) result
(** [customer_cloud_defaults ~registry ~image_tag ~emit_to ()] returns
    [Customer_gitops] when [emit_to] is [Some _], and [Customer_direct]
    otherwise. Returns [Error msg] if [registry] is empty or whitespace-only,
    because there is no implicit registry for customer clusters. *)

(** {2 Accessors} *)

val image_tag : t -> string
val registry : t -> string

(** {2 Conversion} *)

val default_secret_backend : t -> Sol_cli_manifest.secret_backend
(** [default_secret_backend t] derives the correct secret backend from the
    deployment target:
    - [Local] and [Customer_direct] → [Kubernetes_live] (real credentials are
      read from the process environment and applied directly).
    - [Customer_gitops] → [Kubernetes_placeholder] (redacted manifest; no
      plaintext values are written to the GitOps repository).
    - [Sol_hosted] → [Kubernetes_placeholder] (managed by the Sol platform).

    Use this to populate [env_config.secret_backend] before the user's explicit
    [--secret-backend] override is applied. [cmd_deploy.ml] additionally guards
    against [Customer_gitops + Kubernetes_live] at the CLI layer. *)

val to_env_config : name:string -> t -> Sol_cli_deployment_plan.env_config
(** [to_env_config ~name t] converts an env target into the
    [Sol_cli_deployment_plan.env_config] expected by
    [Sol_cli_deployment_plan.of_services]. The [secret_backend] field is
    populated using [default_secret_backend t]. *)
