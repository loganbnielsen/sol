type t =
  | Local of { image_tag : string; cluster_registry : string }
  | Customer_direct of { image_tag : string; registry : string }
  | Customer_gitops of { image_tag : string; registry : string }
  | Sol_hosted of { image_tag : string; registry : string }

let local_defaults ~image_tag =
  Local { image_tag; cluster_registry = "sol-registry:5000" }

let customer_cloud_defaults ~registry ~image_tag ~emit_to () =
  if String.length (String.trim registry) = 0 then
    Error
      "registry must be set for customer cluster deployments (pass --registry \
       <prefix>, or set registry in the resolved target's \
       sol/<env>/<provider>/<region>.yml). See \
       docs/deployment/self-hosted-substrate-contract.md for the full \
       substrate contract."
  else
    match emit_to with
    | Some _ -> Ok (Customer_gitops { image_tag; registry })
    | None -> Ok (Customer_direct { image_tag; registry })

let image_tag = function
  | Local { image_tag; _ }
  | Customer_direct { image_tag; _ }
  | Customer_gitops { image_tag; _ }
  | Sol_hosted { image_tag; _ } ->
      image_tag

let registry = function
  | Local { cluster_registry; _ } -> cluster_registry
  | Customer_direct { registry; _ }
  | Customer_gitops { registry; _ }
  | Sol_hosted { registry; _ } ->
      registry

let deployment_mode_of_target = function
  | Local _ -> Sol_cli_deployment_plan.Local
  | Customer_direct _ -> Sol_cli_deployment_plan.Customer_cloud
  | Customer_gitops _ -> Sol_cli_deployment_plan.Customer_cloud
  | Sol_hosted _ -> Sol_cli_deployment_plan.Sol_hosted

(** Derive the default secret backend from the deployment target.
    - [Local] and [Customer_direct]: apply real credentials live via
      [Kubernetes_live] (values are read from the process environment).
    - [Customer_gitops]: emit a redacted placeholder Secret so that plaintext
      values are never written to the GitOps repository.
    - [Sol_hosted]: emit a redacted placeholder Secret; real secrets are managed
      by the Sol platform out-of-band.

    The CLI guard in [cmd_deploy.ml] additionally rejects any explicit
    [--secret-backend kubernetes-live] override on a GitOps target. *)
let default_secret_backend : t -> Sol_cli_manifest.secret_backend = function
  | Local _ -> Sol_cli_manifest.Kubernetes_live
  | Customer_direct _ -> Sol_cli_manifest.Kubernetes_live
  | Customer_gitops _ -> Sol_cli_manifest.Kubernetes_placeholder
  | Sol_hosted _ -> Sol_cli_manifest.Kubernetes_placeholder

let to_env_config ~name t : Sol_cli_deployment_plan.env_config =
  {
    name;
    mode = deployment_mode_of_target t;
    registry = registry t;
    image_tag = image_tag t;
    env = None;
    region = None;
    base_domain = None;
    secret_backend = default_secret_backend t;
  }
