type ownership =
  | Direct
  | Direct_not_recoverable of string
  | In_cluster of string
  | Synthetic of string
  | External_by_contract of string

type entry =
  { address : string
  ; ownership : ownership
  ; identity : string
  ; import_identity : string
  }

type type_rule =
  { terraform_type : string
  ; ownership : ownership
  }

let entry address ownership ~identity ~import_identity =
  { address; ownership; identity; import_identity }
;;

let direct = Direct

let ownership_kind = function
  | Direct -> "Direct"
  | Direct_not_recoverable _ -> "Direct_not_recoverable"
  | In_cluster _ -> "In_cluster"
  | Synthetic _ -> "Synthetic"
  | External_by_contract _ -> "External_by_contract"
;;

let ownership_reason = function
  | Direct ->
    "Terraform declares it and can destroy it; if the provider holds one that the state \
     does not, Terraform ownership can be restored through its import identity"
  | Direct_not_recoverable reason -> reason
  | In_cluster reason -> reason
  | Synthetic reason -> reason
  | External_by_contract reason -> reason
;;

let not_recoverable =
  Direct_not_recoverable
    "Terraform declares it and can destroy it, but Sol has not established an \
     unambiguous import      identity for this class, so ownership cannot be restored by \
     guesswork -- the boundary is      reported rather than crossed"
;;

let in_cluster =
  In_cluster
    "Terraform declares it, but the object lives inside the cluster: its absence follows \
     from the cluster's, and it has no provider identity of its own to recover"
;;

let synthetic =
  Synthetic
    "Terraform-internal bookkeeping: it creates no provider object, so there is nothing \
     outside the state to recover"
;;

let external_by_contract =
  External_by_contract
    "durable or external by contract: it outlives the target and is not this target's \
     residue to reclaim"
;;

let type_rules =
  [ { terraform_type = "kubernetes_"; ownership = in_cluster }
  ; { terraform_type = "helm_"; ownership = in_cluster }
  ; { terraform_type = "terraform_data"; ownership = synthetic }
  ; { terraform_type = "random_"; ownership = synthetic }
  ; { terraform_type = "null_resource"; ownership = synthetic }
  ]
;;

let gcp ~cluster_name =
  [ entry
      "google_compute_network.main"
      direct
      ~identity:"the target's own VPC"
      ~import_identity:cluster_name
  ; entry
      "google_compute_subnetwork.main"
      direct
      ~identity:(cluster_name ^ "-nodes")
      ~import_identity:(cluster_name ^ "-nodes")
  ; entry
      "google_compute_router.main"
      direct
      ~identity:(cluster_name ^ "-router")
      ~import_identity:(cluster_name ^ "-router")
  ; entry
      "google_compute_router_nat.main"
      direct
      ~identity:(cluster_name ^ "-nat")
      ~import_identity:(cluster_name ^ "-router/" ^ cluster_name ^ "-nat")
  ; entry
      "google_container_cluster.main"
      direct
      ~identity:cluster_name
      ~import_identity:cluster_name
  ; entry
      "google_container_node_pool.main"
      direct
      ~identity:(cluster_name ^ "-nodes")
      ~import_identity:(cluster_name ^ "/" ^ cluster_name ^ "-nodes")
  ; entry
      "google_artifact_registry_repository.images"
      direct
      ~identity:cluster_name
      ~import_identity:cluster_name
  ; entry
      "google_sql_database_instance.postgres"
      direct
      ~identity:(cluster_name ^ "-postgres")
      ~import_identity:(cluster_name ^ "-postgres")
  ; entry
      "google_sql_database.app"
      direct
      ~identity:"app"
      ~import_identity:("app/" ^ cluster_name ^ "-postgres")
  ; entry
      "google_sql_user.postgres"
      direct
      ~identity:"postgres"
      ~import_identity:("postgres/" ^ cluster_name ^ "-postgres")
  ; entry
      "google_compute_global_address.sql_peering"
      direct
      ~identity:(cluster_name ^ "-sql-peering")
      ~import_identity:(cluster_name ^ "-sql-peering")
  ; entry
      "google_service_account.provisioner"
      direct
      ~identity:(cluster_name ^ "-provisioner")
      ~import_identity:(cluster_name ^ "-provisioner")
  ; entry
      "google_storage_bucket.loki"
      external_by_contract
      ~identity:(cluster_name ^ "-loki-logs")
      ~import_identity:(cluster_name ^ "-loki-logs")
  ; entry
      "google_storage_bucket.thanos"
      external_by_contract
      ~identity:(cluster_name ^ "-thanos-metrics")
      ~import_identity:(cluster_name ^ "-thanos-metrics")
  ; entry
      "google_service_account.loki"
      direct
      ~identity:(cluster_name ^ "-loki")
      ~import_identity:(cluster_name ^ "-loki")
  ; entry
      "google_service_account.thanos"
      direct
      ~identity:(cluster_name ^ "-thanos")
      ~import_identity:(cluster_name ^ "-thanos")
  ; entry
      "google_service_account.cert_manager"
      direct
      ~identity:(cluster_name ^ "-cert-manager")
      ~import_identity:(cluster_name ^ "-cert-manager")
  ; entry
      "google_project_iam_custom_role.provisioner_cluster_access"
      direct
      ~identity:("sol_" ^ cluster_name ^ "_cluster_access")
      ~import_identity:("projects/-/roles/sol_" ^ cluster_name ^ "_cluster_access")
  ; entry
      "google_project_iam_custom_role.cert_manager_dns_records"
      direct
      ~identity:("sol_" ^ cluster_name ^ "_cert_manager_dns_records")
      ~import_identity:
        ("projects/-/roles/sol_" ^ cluster_name ^ "_cert_manager_dns_records")
  ; entry
      "google_project_iam_custom_role.cert_manager_dns_discovery"
      direct
      ~identity:("sol_" ^ cluster_name ^ "_cert_manager_dns_discovery")
      ~import_identity:
        ("projects/-/roles/sol_" ^ cluster_name ^ "_cert_manager_dns_discovery")
  ; entry
      "google_service_networking_connection.sql"
      not_recoverable
      ~identity:(cluster_name ^ " (the Cloud SQL peering)")
      ~import_identity:""
  ; entry
      "google_artifact_registry_repository_iam_member.gke_pull"
      not_recoverable
      ~identity:"the registry pull grant"
      ~import_identity:""
  ; entry
      "google_project_iam_member.provisioner_cluster_access"
      not_recoverable
      ~identity:"the provisioner's cluster-access grant"
      ~import_identity:""
  ; entry
      "google_service_account_iam_member.provisioner_impersonators"
      not_recoverable
      ~identity:"who may impersonate the provisioner"
      ~import_identity:""
  ; entry
      "google_storage_bucket_iam_member.loki"
      not_recoverable
      ~identity:"Loki's bucket grant"
      ~import_identity:""
  ; entry
      "google_storage_bucket_iam_member.thanos"
      not_recoverable
      ~identity:"Thanos's bucket grant"
      ~import_identity:""
  ; entry
      "google_service_account_iam_member.loki_workload_identity"
      not_recoverable
      ~identity:"Loki's workload identity binding"
      ~import_identity:""
  ; entry
      "google_service_account_iam_member.thanos_workload_identity"
      not_recoverable
      ~identity:"Thanos's workload identity binding"
      ~import_identity:""
  ; entry
      "google_service_account_iam_member.cert_manager_workload_identity"
      not_recoverable
      ~identity:"cert-manager's workload identity binding"
      ~import_identity:""
  ; entry
      "google_dns_managed_zone_iam_member.cert_manager_dns_records"
      not_recoverable
      ~identity:"cert-manager's DNS record grant"
      ~import_identity:""
  ; entry
      "google_project_iam_member.cert_manager_dns_discovery"
      not_recoverable
      ~identity:"cert-manager's DNS discovery grant"
      ~import_identity:""
  ; entry
      "google_dns_managed_zone.main"
      external_by_contract
      ~identity:"the target's base domain"
      ~import_identity:""
  ]
;;

let aws ~cluster_name =
  [ entry
      "aws_db_instance.postgres"
      direct
      ~identity:(cluster_name ^ "-postgres")
      ~import_identity:(cluster_name ^ "-postgres")
  ; entry
      "aws_db_subnet_group.main"
      direct
      ~identity:(cluster_name ^ "-postgres")
      ~import_identity:(cluster_name ^ "-postgres")
  ; entry
      "aws_security_group.rds"
      direct
      ~identity:(cluster_name ^ "-rds")
      ~import_identity:(cluster_name ^ "-rds")
  ; entry
      "aws_ecr_repository.services"
      not_recoverable
      ~identity:"the target's registry path"
      ~import_identity:""
  ; entry
      "aws_s3_bucket.loki"
      external_by_contract
      ~identity:(cluster_name ^ "-loki-logs")
      ~import_identity:(cluster_name ^ "-loki-logs")
  ; entry
      "aws_s3_bucket.thanos"
      external_by_contract
      ~identity:(cluster_name ^ "-thanos-metrics")
      ~import_identity:(cluster_name ^ "-thanos-metrics")
  ; entry
      "aws_route53_zone.main"
      external_by_contract
      ~identity:"the target's base domain"
      ~import_identity:""
  ; entry
      "aws_ecr_lifecycle_policy.services"
      not_recoverable
      ~identity:"the target's registry lifecycle"
      ~import_identity:""
  ; entry
      "aws_eks_addon.ebs_csi_driver"
      direct
      ~identity:(cluster_name ^ ":aws-ebs-csi-driver")
      ~import_identity:(cluster_name ^ ":aws-ebs-csi-driver")
  ; entry
      "aws_s3_bucket_lifecycle_configuration.loki"
      direct
      ~identity:(cluster_name ^ "-loki-logs")
      ~import_identity:(cluster_name ^ "-loki-logs")
  ; entry
      "aws_iam_policy.cert_manager"
      not_recoverable
      ~identity:(cluster_name ^ "-cert-manager")
      ~import_identity:""
  ; entry
      "aws_iam_policy.grafana_cloudwatch"
      not_recoverable
      ~identity:(cluster_name ^ "-grafana-cloudwatch")
      ~import_identity:""
  ; entry
      "aws_iam_policy.loki_s3"
      not_recoverable
      ~identity:(cluster_name ^ "-loki-s3")
      ~import_identity:""
  ; entry
      "aws_iam_policy.thanos_s3"
      not_recoverable
      ~identity:(cluster_name ^ "-thanos-s3")
      ~import_identity:""
  ; entry
      "aws_cloudwatch_dashboard.managed_resource"
      not_recoverable
      ~identity:(cluster_name ^ "-*")
      ~import_identity:""
  ]
;;
