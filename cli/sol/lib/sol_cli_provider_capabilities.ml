(* REFAC-095: what Sol needs to know about a provider, as data, selected in one
   place.

   Generic lifecycle code used to reach this knowledge through a
   `match provider with Aws -> ... | Gcp -> ...` at each call site: the platform
   root, the backend arguments, the variables each root declares, the bootstrap
   authority's Terraform identity, the guarded addresses. Each is now a field of
   one record per provider, and [capabilities_of] is the only provider match. It
   has no wildcard arm, so a new provider does not compile until its record
   exists: nothing inherits another provider's behaviour, which is exactly what
   the two `| _` arms this replaced did (SEC-010's class).

   Only table-shaped capabilities live here. Cluster access, retention and
   non-Terraform residue need provider-private types and move behind their own
   capabilities later (REFAC-096, REFAC-097). *)

type platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

type t =
  { platform_root : string
  ; platform_address : string -> string
  ; backend_config :
      Sol_cli_config.target
      -> bucket:string
      -> object_key:string
      -> (string list, string) result
  ; cluster_access_role_arn : Sol_cli_config.target -> (string option, string) result
  ; platform_storage : platform_storage
  ; own_vars :
      Sol_cli_config.target
      -> workspace:string
      -> (string * string) list
      -> (string * string) list
  ; profile_vars : production:bool -> production_postgres:bool -> (string * string) list
  ; guarded_removals : string list
    (** Resource types whose removal discards something a re-apply cannot restore, so the
        apply sequence refuses a plan that removes one unless it is confirmed
        (AUDIT-POST-002). Empty is a real answer for a provider whose own API refuses
        such a deletion. *)
  ; root_declared_vars :
      has_postgres:bool
      -> production_postgres:bool
      -> ecr_repositories:(unit -> (string, string) result)
      -> ((string * string) list, string) result
  ; destroy_guard_vars : final_snapshot:string option -> (string * string) list
  ; bootstrap_matchers : Sol_cli_terraform_plan.matcher list
  ; bootstrap_scope : Sol_cli_terraform.scope
  ; reconciliation_scope : string list -> Sol_cli_terraform.scope
  ; guarded_addresses : string list
  ; cloud_ready_expectation : string
  ; production_qualified : bool
  ; sol_keys : string list
  ; state_locking : string option
  ; scoped_identities : string list
  }

let add_opt k = function
  | None -> Fun.id
  | Some v -> fun xs -> (k, v) :: xs
;;

let required name = function
  | Some value when String.trim value <> "" -> Ok (String.trim value)
  | _ -> Error ("the cloud lifecycle requires target." ^ name)
;;

(* AWS. The bootstrap-access mechanism is an access-policy association owned by
   the `eks` module, whose internal address is module-version-dependent -- naming
   it by address would be a guess that could not be validated offline, and a wrong
   `-target` fails closed but strands the target. So the module is the smallest
   *stable* scope that contains it, the matcher names the resource type, and the
   plan assertion is what keeps it narrow. *)
let aws =
  { platform_root = "platform/infra/base"
  ; platform_address = Fun.id
  ; backend_config =
      (fun (target : Sol_cli_config.target) ~bucket ~object_key ->
        (* S3 has no native locking, so the DynamoDB lock table is part of what
           makes the state durable, not an option. *)
        match Sol_cli_config.provider_field target "state_lock_table" with
        | Some table when String.trim table <> "" ->
          Ok
            [ "bucket=" ^ bucket
            ; "key=" ^ object_key
            ; "region=" ^ target.region
            ; "dynamodb_table=" ^ String.trim table
            ; "encrypt=true"
            ]
        | _ ->
          Error
            "an AWS target must declare aws.state_lock_table: S3 has no native state \
             locking, so two applies could corrupt the same state")
  ; cluster_access_role_arn =
      (fun (target : Sol_cli_config.target) ->
        Result.map
          Option.some
          (required
             "aws.cluster_access_role_arn"
             (Sol_cli_config.provider_field target "cluster_access_role_arn")))
  ; (* EKS ships no default StorageClass, so Sol creates one. *)
    platform_storage = { storage_class = "gp3"; csi_driver = "ebs.csi.aws.com" }
  ; own_vars =
      (fun (target : Sol_cli_config.target) ~workspace shared ->
        shared
        |> add_opt "cluster_endpoint_cidr" target.cluster_endpoint_cidr
        |> add_opt
             "provisioner_role_arn"
             (Sol_cli_config.provider_field target "provisioner_role_arn")
        |> add_opt
             "cluster_access_role_arn"
             (Sol_cli_config.provider_field target "cluster_access_role_arn")
        (* HARDEN-002 run 3, finding 11: deploy_role_arn is declared by the
           provider root (platform/infra/aws) and drives the deploy EKS
           access entry INFRA-025 added, but was never routed here — so the entry
           was never created and the module's deploy_kubeconfig_command/
           deploy_kube_context outputs stayed null. provider_fields still follow,
           so a target can override.

           DEC-038 routes operator_role_arn the same way. It used to be excluded
           on the grounds that the AWS root did not declare it -- which was true,
           and was the reason the operator identity Sol documents could not exist:
           the ARN was parsed, stored, printed in examples, and never reached
           anything that could act on it. The root now declares it (the operator's
           read-only EKS access entry), so it is routed here like the others. A
           declared identity that never reaches the root is the same bug class as
           the one this comment records. *)
        |> add_opt
             "deploy_role_arn"
             (Sol_cli_config.provider_field target "deploy_role_arn")
        |> add_opt
             "operator_role_arn"
             (Sol_cli_config.provider_field target "operator_role_arn")
        |> add_opt "workspace_name" (Some workspace))
  ; profile_vars =
      (fun ~production ~production_postgres ->
        (* INFRA-030: the profile owns the cluster shape, so the platform's own
           components cannot be starved by the module defaults. The shape names AWS
           instance types, which is why it is AWS's. A production-profile RDS
           instance stays protected regardless of any --var the caller supplies;
           the variable defaults to true, so it is only ever forced here. *)
        (if production
         then Sol_cli_profile.node_shape_vars Sol_cli_profile.recommended_node_shape
         else [])
        @ if production_postgres then [ "rds_deletion_protection", "true" ] else [])
  ; (* INFRA-074 / AUDIT-POST-002: removing one of these takes its contents with it
       ([force_delete = true]), and the list is derived from the workloads in the invoking
       checkout, so a branch that lacks a Dockerfile plans a deletion. Sol refuses that
       unless the operator confirms it. *)
    guarded_removals = [ "aws_ecr_repository" ]
  ; root_declared_vars =
      (fun ~has_postgres ~production_postgres ~ecr_repositories ->
        Result.map
          (fun ecr_repositories ->
             [ "create_rds", string_of_bool has_postgres
             ; "rds_multi_az", string_of_bool production_postgres
             ; "ecr_repositories", ecr_repositories
             ])
          (ecr_repositories ()))
  ; destroy_guard_vars =
      (fun ~final_snapshot ->
        ("rds_deletion_protection", "false")
        ::
        (match final_snapshot with
         | Some identifier ->
           [ "rds_skip_final_snapshot", "false"
           ; "rds_final_snapshot_identifier", identifier
           ]
         | None -> [ "rds_skip_final_snapshot", "true" ]))
  ; bootstrap_matchers =
      [ Sol_cli_terraform_plan.Type "aws_eks_access_policy_association" ]
  ; bootstrap_scope = Sol_cli_terraform.targets "module.eks" []
  ; reconciliation_scope = Sol_cli_terraform.targets "module.eks"
  ; guarded_addresses = [ "aws_db_instance.postgres" ]
  ; cloud_ready_expectation = "the EKS cluster and its EBS CSI addon are ACTIVE"
  ; production_qualified = true
  ; (* REFAC-098: the provider-block keys Sol consumes itself. They are routed above
       (or are backend configuration), never passed through as `-var`s. *)
    sol_keys =
      [ "state_lock_table"
      ; "provisioner_role_arn"
      ; "cluster_access_role_arn"
      ; "deploy_role_arn"
      ; "operator_role_arn"
      ]
  ; (* S3 has no native locking, so the lock table is part of a conformant backend. *)
    state_locking = Some "state_lock_table"
  ; (* AUDIT-072: named identities distinct from the cluster-creator admin. *)
    scoped_identities =
      [ "provisioner_role_arn"
      ; "cluster_access_role_arn"
      ; "deploy_role_arn"
      ; "operator_role_arn"
      ]
  }
;;

(* GCP. The platform root reaches the shared definition through a module, so its
   addresses carry that prefix; GCS locks natively and addresses an object by
   `prefix`; the bootstrap-access mechanism is a root-level resource with a
   stable address. *)
let gcp_bootstrap_binding = "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"

let gcp =
  { platform_root = "platform/infra/base-gcp"
  ; platform_address = (fun address -> "module.platform." ^ address)
  ; backend_config =
      (fun _target ~bucket ~object_key ->
        Ok [ "bucket=" ^ bucket; "prefix=" ^ object_key ])
  ; (* A GCP caller impersonates a service account through short-lived
       credentials; there is no role to name. *)
    cluster_access_role_arn = (fun _target -> Ok None)
  ; (* GKE ships `standard-rwo` already annotated as the default, so Sol adopts it
       rather than creating a second default class. *)
    platform_storage =
      { storage_class = "standard-rwo"; csi_driver = "pd.csi.storage.gke.io" }
  ; own_vars =
      (fun (target : Sol_cli_config.target) ~workspace:_ shared ->
        (* The impersonation grant is GCP's, and only GCP's: the AWS equivalent is
           the provisioner role's trust policy, not a variable that root declares.
           A target that names no caller gets no grant at all, rather than the
           caller's own identity. *)
        shared
        |> add_opt
             "provisioner_impersonators"
             (Option.map
                (fun member -> Printf.sprintf "[%S]" member)
                (Sol_cli_config.provider_field target "provisioner_impersonator"))
        (* INFRA-077 / FND-0057: Cloud Storage soft-deletes and bills deleted objects
           for 7 days by default, so a `destroy_retention: none` destroy would leave
           the observability data billed. `none` creates the buckets with soft delete
           off; anything else declares the 7 days explicitly. *)
        |> add_opt
             "gcs_soft_delete_retention_seconds"
             (Some
                (match Option.map String.trim target.destroy_retention with
                 | Some "none" -> "0"
                 | _ -> "604800")))
  ; (* The GCP root keeps Cloud SQL deletion protection on by its own default
       (sql_deletion_protection = true), and declares no node-shape variables. *)
    profile_vars = (fun ~production:_ ~production_postgres:_ -> [])
  ; (* No equivalent, and that is the honest answer: an Artifact Registry repository
       cannot be deleted while it holds images, so the provider refuses the deletion
       itself and there is nothing here for Sol to confirm. A different risk shape, not a
       missing guard (AUDIT-POST-002). *)
    guarded_removals = []
  ; (* The GCP root declares its own database variables (`project_id` and the Cloud
       SQL shapes), which a target supplies through its provider block. *)
    root_declared_vars =
      (fun ~has_postgres:_ ~production_postgres:_ ~ecr_repositories:_ -> Ok [])
  ; destroy_guard_vars =
      (fun ~final_snapshot:_ ->
        [ "sql_deletion_protection", "false"; "gke_deletion_protection", "false" ])
  ; (* FND-0058: the binding is `count = var.provisioner_bootstrap_admin ? 1 : 0`,
       so Terraform's plan address for it is
       `kubernetes_cluster_role_binding.provisioner_bootstrap_admin[0]`.
       [Resource] names the resource and every instance of it; [Exact] would name
       an address Terraform never emits, so the authority create the destroy
       policy permits would be refused by that policy's own guard. [Type] is
       wrong here for the opposite reason: the platform declares other
       `kubernetes_cluster_role_binding`s. *)
    bootstrap_matchers = [ Sol_cli_terraform_plan.Resource gcp_bootstrap_binding ]
  ; bootstrap_scope = Sol_cli_terraform.targets gcp_bootstrap_binding []
  ; reconciliation_scope = Sol_cli_terraform.targets gcp_bootstrap_binding
  ; guarded_addresses =
      [ "google_sql_database_instance.postgres"; "google_container_cluster.main" ]
  ; cloud_ready_expectation =
      "the GKE cluster is RUNNING and the Cloud SQL instance is RUNNABLE"
  ; production_qualified = false
  ; sol_keys = [ "provisioner_impersonator" ]
  ; (* GCS locks natively. *)
    state_locking = None
  ; scoped_identities = []
  }
;;

let capabilities_of = function
  | Sol_cli_provider.Aws -> aws
  | Sol_cli_provider.Gcp -> gcp
;;
