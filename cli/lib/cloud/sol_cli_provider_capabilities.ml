type platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

type t =
  { backend_config :
      Sol_cli_config.target
      -> bucket:string
      -> object_key:string
      -> (string list, string) result
  ; cluster_access_role_arn : Sol_cli_config.target -> (string option, string) result
  ; platform_storage : platform_storage
  ; cluster_substrate :
      (outputs_json:string
       -> region:string
       -> cluster_name:string
       -> (Sol_cli_cluster_substrate.t, string) result)
        option
  ; disk_quota :
      (outputs_json:string
       -> region:string
       -> (Sol_cli_disk_quota.observation, string) result)
        option
  ; installation_prerequisites : Sol_cli_installation.prerequisite list
  ; installation_probes :
      Sol_cli_installation.installation_config -> Sol_cli_installation.probe list
  ; installation_backend :
      Sol_cli_installation.installation_config -> (string list, string) result
  ; installation_vars :
      manage_dns_zone:bool
      -> Sol_cli_installation.installation_config
      -> (string * string) list
  ; installation_zone_address : string
  ; installation_nameservers_output : string
  ; own_vars :
      Sol_cli_config.target
      -> workspace:string
      -> (string * string) list
      -> (string * string) list
  ; profile_vars : production:bool -> production_postgres:bool -> (string * string) list
  ; guarded_removals : string list
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

let dns_declaration
      ~manage_dns_zone
      (configuration : Sol_cli_installation.installation_config)
  =
  if not manage_dns_zone
  then "false", ""
  else (
    match Sol_cli_installation.zone_domain configuration.zone with
    | None -> "false", ""
    | Some domain -> "true", domain)
;;

let add_opt k = function
  | None -> Fun.id
  | Some v -> fun xs -> (k, v) :: xs
;;

let required name value =
  Option.to_result ~none:("the cloud lifecycle requires target." ^ name) value
;;

let aws =
  { backend_config =
      (fun target ~bucket ~object_key ->
        match Sol_cli_config.provider_field target "state_lock_table" with
        | Some table ->
          Ok
            [ "bucket=" ^ bucket
            ; "key=" ^ object_key
            ; "region=" ^ target.region
            ; "dynamodb_table=" ^ table
            ; "encrypt=true"
            ]
        | _ ->
          Error
            "an AWS target must declare aws.state_lock_table: S3 has no native state \
             locking, so two applies could corrupt the same state")
  ; cluster_access_role_arn =
      (fun target ->
        Result.map
          Option.some
          (required
             "aws.cluster_access_role_arn"
             (Sol_cli_config.provider_field target "cluster_access_role_arn")))
  ; platform_storage = { storage_class = "gp3"; csi_driver = "ebs.csi.aws.com" }
  ; cluster_substrate = None
  ; disk_quota = None
  ; installation_prerequisites =
      [ Sol_cli_installation.State_backend
      ; Sol_cli_installation.State_lock
      ; Sol_cli_installation.Provisioning_identity
      ; Sol_cli_installation.Cluster_access_identity
      ; Sol_cli_installation.Deploy_identity
      ; Sol_cli_installation.Operator_identity
      ; Sol_cli_installation.Delegated_zone
      ]
  ; installation_probes =
      (fun configuration ->
        let open Sol_cli_installation in
        let role_name arn =
          let after needle =
            let n = String.length needle in
            let rec scan i =
              if i + n > String.length arn
              then None
              else if String.sub arn i n = needle
              then Some (String.sub arn (i + n) (String.length arn - i - n))
              else scan (i + 1)
            in
            scan 0
          in
          match after ":role/" with
          | Some name -> name
          | None ->
            (match String.rindex_opt arn '/' with
             | Some i when i + 1 < String.length arn ->
               String.sub arn (i + 1) (String.length arn - i - 1)
             | _ -> arn)
        in
        let role prerequisite name =
          match name with
          | Some arn ->
            present_if_output
              prerequisite
              [ "aws"; "iam"; "get-role"; "--role-name"; role_name arn ]
          | None ->
            absent
              prerequisite
              (Printf.sprintf
                 "the resolved installation configuration names no %s"
                 (prerequisite_label prerequisite))
        in
        [ present_if_output
            State_backend
            [ "aws"
            ; "s3api"
            ; "head-bucket"
            ; "--bucket"
            ; configuration.state_bucket
            ; "--region"
            ; configuration.region
            ]
        ; (match configuration.lock_table with
           | Some table ->
             present_if_output
               State_lock
               [ "aws"
               ; "dynamodb"
               ; "describe-table"
               ; "--table-name"
               ; table
               ; "--region"
               ; configuration.region
               ]
           | None ->
             absent
               State_lock
               "the resolved installation configuration names no lock table, and the AWS \
                durable root declares one")
        ; role Provisioning_identity configuration.provisioning_identity
        ; role Cluster_access_identity configuration.cluster_access_identity
        ; role Deploy_identity configuration.deploy_identity
        ; role Operator_identity configuration.operator_identity
        ]
        @
        match configuration.zone with
        | No_zone -> []
        | Service_zone { domain; ownership = Externally_delegated } ->
          [ unverifiable
              Delegated_zone
              (Printf.sprintf
                 "%s is externally delegated: the zone lives outside AWS, so the \
                  delegation to this installation cannot be observed where the \
                  installation looks — confirming it is the delegation wait, not a \
                  provider lookup"
                 domain)
          ]
        | Service_zone { domain; ownership } ->
          [ present_if_output_names
              ~present:(fun output -> Sol_cli_string.contains ~needle:domain output)
              ~reason:
                (Printf.sprintf
                   "no Route53 hosted zone named %s, although the target declares it %s"
                   domain
                   (match ownership with
                    | Sol_created -> "sol-created"
                    | User_supplied -> "user-supplied"
                    | Externally_delegated -> "(external)"))
              Delegated_zone
              [ "aws"; "route53"; "list-hosted-zones-by-name"; "--dns-name"; domain ]
          ])
  ; installation_backend =
      (fun configuration ->
        match configuration.lock_table with
        | None ->
          Error
            "an AWS installation must declare aws.state_lock_table before the durable \
             root can be reconciled: S3 has no native state locking, so a root whose \
             backend names no lock table could corrupt its own state"
        | Some table ->
          Ok
            [ "bucket=" ^ configuration.state_bucket
            ; "key=" ^ configuration.state_prefix ^ "/default.tfstate"
            ; "region=" ^ configuration.region
            ; "dynamodb_table=" ^ table
            ; "encrypt=true"
            ])
  ; installation_vars =
      (fun ~manage_dns_zone configuration ->
        [ "region", configuration.region
        ; "state_bucket", configuration.state_bucket
        ; "state_lock_table", Option.value configuration.lock_table ~default:""
        ; "manage_dns_zone", fst (dns_declaration ~manage_dns_zone configuration)
        ; "base_domain", snd (dns_declaration ~manage_dns_zone configuration)
        ])
  ; own_vars =
      (fun target ~workspace shared ->
        shared
        |> add_opt "cluster_endpoint_cidr" target.cluster_endpoint_cidr
        |> add_opt
             "provisioner_role_arn"
             (Sol_cli_config.provider_field target "provisioner_role_arn")
        |> add_opt
             "cluster_access_role_arn"
             (Sol_cli_config.provider_field target "cluster_access_role_arn")
        |> add_opt
             "deploy_role_arn"
             (Sol_cli_config.provider_field target "deploy_role_arn")
        |> add_opt
             "operator_role_arn"
             (Sol_cli_config.provider_field target "operator_role_arn")
        |> add_opt "workspace_name" (Some workspace))
  ; profile_vars =
      (fun ~production ~production_postgres ->
        (if production
         then Sol_cli_profile.node_shape_vars Sol_cli_profile.recommended_node_shape
         else [])
        @ if production_postgres then [ "rds_deletion_protection", "true" ] else [])
  ; guarded_removals = [ "aws_ecr_repository" ]
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
  ; sol_keys =
      [ "state_lock_table"
      ; "provisioner_role_arn"
      ; "cluster_access_role_arn"
      ; "deploy_role_arn"
      ; "operator_role_arn"
      ]
  ; state_locking = Some "state_lock_table"
  ; installation_zone_address = "aws_route53_zone.qualification"
  ; installation_nameservers_output = "name_servers"
  ; scoped_identities =
      [ "provisioner_role_arn"
      ; "cluster_access_role_arn"
      ; "deploy_role_arn"
      ; "operator_role_arn"
      ]
  }
;;

let gcp_bootstrap_binding = "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"

let gcp =
  { backend_config =
      (fun _target ~bucket ~object_key ->
        Ok [ "bucket=" ^ bucket; "prefix=" ^ object_key ])
  ; cluster_access_role_arn = (fun _target -> Ok None)
  ; platform_storage =
      { storage_class = "standard-rwo"; csi_driver = "pd.csi.storage.gke.io" }
  ; cluster_substrate =
      Some
        (fun ~outputs_json ~region ~cluster_name ->
          Sol_cli_gcp_cluster.substrate_of_describe ~outputs_json ~region ~cluster_name)
  ; disk_quota =
      Some
        (fun ~outputs_json ~region ->
          Sol_cli_gcp_cluster.disk_quota ~outputs_json ~region)
  ; installation_prerequisites =
      [ Sol_cli_installation.State_backend; Sol_cli_installation.Delegated_zone ]
  ; installation_probes =
      (fun configuration ->
        let open Sol_cli_installation in
        let zone_name =
          match Sol_cli_installation.zone_domain configuration.zone with
          | None -> None
          | Some domain ->
            Some
              (String.map
                 (function
                   | '.' -> '-'
                   | character -> character)
                 domain)
        in
        [ present_if_output_names
            ~reason:
              (Printf.sprintf
                 "no Cloud Storage bucket gs://%s"
                 configuration.state_bucket)
            State_backend
            [ "gcloud"
            ; "storage"
            ; "buckets"
            ; "describe"
            ; Printf.sprintf "gs://%s" configuration.state_bucket
            ; "--format=value(name)"
            ]
        ]
        @
        match configuration.zone, zone_name with
        | No_zone, _ -> []
        | Service_zone { domain; ownership = Externally_delegated }, _ ->
          [ unverifiable
              Delegated_zone
              (Printf.sprintf
                 "%s is externally delegated: the zone lives outside Google Cloud, so \
                  the delegation to this installation cannot be observed where the \
                  installation looks — confirming it is the delegation wait, not a \
                  provider lookup"
                 domain)
          ]
        | Service_zone { ownership; _ }, None ->
          [ unverifiable
              Delegated_zone
              (Printf.sprintf
                 "the target declares %s zone ownership but names no domain, so the \
                  installation cannot tell which zone to observe"
                 (Sol_cli_installation.zone_ownership_declaration ownership))
          ]
        | Service_zone { domain; ownership }, Some name ->
          [ present_if_output_names
              ~reason:
                (Printf.sprintf
                   "no Cloud DNS managed zone named %s for %s, although the target \
                    declares it %s"
                   name
                   domain
                   (match ownership with
                    | Sol_created -> "sol-created"
                    | User_supplied -> "user-supplied"
                    | Externally_delegated -> "(external)"))
              Delegated_zone
              [ "gcloud"
              ; "dns"
              ; "managed-zones"
              ; "describe"
              ; name
              ; "--format=value(name)"
              ]
          ])
  ; installation_backend =
      (fun configuration ->
        Ok
          [ "bucket=" ^ configuration.state_bucket
          ; "prefix=" ^ configuration.state_prefix
          ])
  ; installation_vars =
      (fun ~manage_dns_zone configuration ->
        [ "project_id", Option.value configuration.project_id ~default:""
        ; "region", configuration.region
        ; "state_bucket", configuration.state_bucket
        ; "manage_dns_zone", fst (dns_declaration ~manage_dns_zone configuration)
        ; "base_domain", snd (dns_declaration ~manage_dns_zone configuration)
        ])
  ; own_vars =
      (fun target ~workspace:_ shared ->
        shared
        |> add_opt
             "provisioner_impersonators"
             (Sol_cli_config.provider_field target "provisioner_impersonator"
              |> Option.map (fun member -> Printf.sprintf "[%S]" member))
        |> add_opt
             "gcs_soft_delete_retention_seconds"
             (Some
                (match Option.map String.trim target.destroy_retention with
                 | Some "none" -> "0"
                 | _ -> "604800")))
  ; profile_vars = (fun ~production:_ ~production_postgres:_ -> [])
  ; guarded_removals = []
  ; root_declared_vars =
      (fun ~has_postgres:_ ~production_postgres:_ ~ecr_repositories:_ -> Ok [])
  ; destroy_guard_vars =
      (fun ~final_snapshot:_ ->
        [ "sql_deletion_protection", "false"; "gke_deletion_protection", "false" ])
  ; bootstrap_matchers = [ Sol_cli_terraform_plan.Resource gcp_bootstrap_binding ]
  ; bootstrap_scope = Sol_cli_terraform.targets gcp_bootstrap_binding []
  ; reconciliation_scope = Sol_cli_terraform.targets gcp_bootstrap_binding
  ; guarded_addresses =
      [ "google_sql_database_instance.postgres"; "google_container_cluster.main" ]
  ; cloud_ready_expectation =
      "the GKE cluster is RUNNING and the Cloud SQL instance is RUNNABLE"
  ; production_qualified = false
  ; sol_keys = [ "provisioner_impersonator" ]
  ; state_locking = None
  ; installation_zone_address = "google_dns_managed_zone.qualification"
  ; installation_nameservers_output = "name_servers"
  ; scoped_identities = []
  }
;;

let capabilities_of = function
  | Sol_cli_provider.Aws -> aws
  | Sol_cli_provider.Gcp -> gcp
;;

let installation_nameservers_output provider =
  (capabilities_of provider).installation_nameservers_output
;;

let installation_prerequisites provider =
  (capabilities_of provider).installation_prerequisites
;;

let installation_probes provider configuration =
  (capabilities_of provider).installation_probes configuration
;;

let installation_backend provider configuration =
  (capabilities_of provider).installation_backend configuration
;;

let installation_vars provider ~manage_dns_zone configuration =
  (capabilities_of provider).installation_vars ~manage_dns_zone configuration
;;
