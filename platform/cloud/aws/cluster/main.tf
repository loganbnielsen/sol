# platform/cloud/aws/cluster — AWS cluster provisioning for Sol workspaces
#
# Provisions:
#   VPC            — public + private subnets across 3 AZs, NAT gateway
#   EKS            — managed cluster with a general-purpose node group
#   ECR            — one repository per service name (list in variables)
#   RDS PostgreSQL — managed database (replaces in-cluster postgres)
#   Route53 zone   — base domain for Ingress / cert-manager
#
# After apply: `sol cloud apply` installs the platform through
# platform/cloud/aws/platform (the shared module platform/cloud/modules/platform).
#
# Usage:
#   terraform init
#   terraform apply -var="cluster_name=acme-prod" -var="base_domain=acme.com"

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# ── VPC ───────────────────────────────────────────────────────────────────── #

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.7"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 4)]

  enable_nat_gateway   = true
  single_nat_gateway   = !var.ha_nat_gateway
  enable_dns_hostnames = true

  # Tags required by EKS for subnet auto-discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = var.tags
}

# ── EKS ───────────────────────────────────────────────────────────────────── #

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true
  # AUDIT-072: restrict the public API endpoint to an explicit CIDR. Empty keeps
  # the module default (0.0.0.0/0) for non-production clusters; a
  # production-single-region target must set cluster_endpoint_cidr, enforced by
  # sol deploy's preflight rather than assumed here.
  cluster_endpoint_public_access_cidrs = (
    var.cluster_endpoint_cidr == "" ? null : [var.cluster_endpoint_cidr]
  )

  # The default vpc-cni addon does not enforce Kubernetes NetworkPolicy
  # resources — sol's generated NetworkPolicies (see BUG-012) are a no-op
  # without this. most_recent pulls a CNI version new enough to ship the
  # network-policy-agent (v1.14+).
  cluster_addons = {
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }

  # HARDEN-002 run 2, finding 7: the qualified substrate had no storage at all --
  # no CSI driver and therefore no StorageClass -- so a persistent Redpanda (RF3,
  # which the profile's durability claim depends on) could never schedule, and
  # neither could any workload volume DEC-026 §3/§5 admits.
  #
  # This is *platform substrate* storage, not an application workload volume: the
  # driver and the role below make the platform's own durability topology (and
  # workload volumes) physically realizable, and they say nothing about how a
  # workload declares persistence. In particular they do not interact with the
  # `single`-tier restriction on workload-declared volumes.
  #
  # The addon is declared outside the EKS module: its service account role is an
  # IRSA role for this cluster's OIDC provider, so referencing it from inside
  # cluster_addons would be a module.eks -> module.ebs_csi_irsa -> module.eks cycle.

  # EKS Managed Node Group — general purpose, autoscaling
  eks_managed_node_groups = {
    general = {
      # Without an explicit name, the module derives the IAM role name from
      # the node-group map key ("general-eks-node-group-*") instead of
      # cluster_name — every cluster's node-group role collides on the same
      # name prefix, which also breaks cluster_name-scoped IAM policies.
      iam_role_name = "${var.cluster_name}-node-group"

      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      disk_size = 50

      labels = { role = "general" }
    }
  }

  # Enable IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # AUDIT-072: no standing cluster-creator admin in the normal path. The
  # production profile uses the named provisioning/deploy/operator identities
  # from the target file; bootstrapping or break-glass that genuinely needs the
  # cluster-creator credential is an explicit, documented, scoped exception
  # (set enable_cluster_creator_admin = true for the one-off bootstrap, then
  # return it to false).
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin

  access_entries = merge(
    var.cluster_access_role_arn == "" ? {} : {
      platform_cluster_access = {
        principal_arn     = var.cluster_access_role_arn
        kubernetes_groups = ["sol:platform-provisioners"]
        policy_associations = var.provisioner_bootstrap_admin ? {
          bootstrap = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        } : {}
      }
    },
    # AUDIT-072 / INFRA-025: group membership only, same as the provisioner's
    # steady state -- no policy_associations. The RBAC grant itself is the
    # cluster-wide (but resource-kind-scoped) ClusterRole in
    # platform/cloud/modules/platform/platform_deploy_rbac.tf, bound per application
    # namespace at runtime by Sol_cli_substrate.ensure (namespaces are created
    # dynamically, so a static Terraform-time namespace list can't express
    # this, and a ClusterRoleBinding would leak deploy into platform
    # namespaces' own Secrets/Deployments).
    var.deploy_role_arn == "" ? {} : {
      deploy = {
        principal_arn     = var.deploy_role_arn
        kubernetes_groups = ["sol:deployers"]
      }
    },
    # ADR 0002 / DEC-038: the operator identity observes production. Group
    # membership only, like the two above -- no policy_associations, because the
    # grant is the read-only ClusterRole in
    # platform/cloud/modules/platform/platform_operator_rbac.tf, bound per application
    # namespace at runtime. Before DEC-038 nothing created this entry at all, so
    # `operator_role_arn` was documented and unreachable: `sol deploy` tells the
    # operator to run `sol status`, and no identity could.
    var.operator_role_arn == "" ? {} : {
      operator = {
        principal_arn     = var.operator_role_arn
        kubernetes_groups = ["sol:operators"]
      }
    },
  )

  tags = var.tags
}

# ── ECR repositories ──────────────────────────────────────────────────────── #
# One repository per service. Images are pushed here by CI; sol deploy reads
# from here using the workspace/service naming convention.

resource "aws_ecr_repository" "services" {
  for_each = toset(var.ecr_repositories)

  # Keyed on workspace_name, not cluster_name: sol deploy constructs image
  # references as "${registry}/${workspace}/${k8s_name}:${tag}"
  # (Sol_cli_deployment_plan.image_ref), independent of which cluster the
  # workspace happens to be deployed to. See FRIC-011.
  name                 = "${var.workspace_name}/${each.value}"
  image_tag_mutability = "MUTABLE"

  # INFRA-037: images are pushed here by the documented publish step, so by the
  # time anyone destroys a target that has deployed once, these repositories are
  # NOT empty. Without [force_delete] the destroy fails with "ECR Repository
  # (...) not empty, consider using force_delete" and leaves the whole target
  # standing -- which is exactly what happened on HARDEN Run 5 Attempt 5.
  #
  # The invariant (ADR 0004): normal lifecycle activity must never make a target
  # undeletable through the normal lifecycle. Artifacts this repository accumulates
  # are produced BY the lifecycle, so the lifecycle has to be able to remove them.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

# Lifecycle policy: keep last 30 images per repo
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

# ── RDS PostgreSQL ────────────────────────────────────────────────────────── #

resource "aws_db_subnet_group" "main" {
  count      = var.create_rds ? 1 : 0
  name       = "${var.cluster_name}-postgres"
  subnet_ids = module.vpc.private_subnets
  tags       = var.tags
}

resource "aws_security_group" "rds" {
  count  = var.create_rds ? 1 : 0
  name   = "${var.cluster_name}-rds"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"
    # Allow traffic from the EKS node security group
    security_groups = [module.eks.node_security_group_id]
  }

  tags = var.tags
}

resource "aws_db_instance" "postgres" {
  count             = var.create_rds ? 1 : 0
  identifier        = "${var.cluster_name}-postgres"
  engine            = "postgres"
  engine_version    = "16.15"
  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_storage_gb
  storage_encrypted = true

  db_name  = "app"
  username = "postgres"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  backup_retention_period = 7
  multi_az                = var.rds_multi_az
  deletion_protection     = var.rds_deletion_protection
  # HARDEN-002 run 2, finding 9. Two things were wrong here:
  #
  #   1. skip_final_snapshot was derived from deletion protection, so the only way
  #      to let Terraform destroy the instance was to stop taking a final snapshot
  #      -- production destruction was either impossible or silent about data;
  #   2. no final_snapshot_identifier was ever set, so with a snapshot required
  #      Terraform refused to destroy at all and `sol cloud destroy` could not
  #      complete.
  #
  # They are separate knobs with production-safe defaults now: protection on, and a
  # final snapshot taken. Terraform is therefore structurally able to destroy the
  # instance, which is what (1) and (2) blocked.
  #
  # Permitting the destruction is still the operator's own step, and NOT something
  # `sol cloud destroy` does: lifting protection is an applied transition, and a
  # `-var` on a destroy is inert because the provider is handed prior state. For the
  # same reason the identifier used at delete time is whatever the last apply
  # rendered, so destroying the same cluster_name twice collides unless a fresh one
  # is applied first. See the known gap in docs/deployment/production-bootstrap.md.
  skip_final_snapshot = var.rds_skip_final_snapshot
  final_snapshot_identifier = (
    var.rds_skip_final_snapshot
    ? null
    : (
      var.rds_final_snapshot_identifier != ""
      ? var.rds_final_snapshot_identifier
      : "${var.cluster_name}-postgres-final"
    )
  )

  tags = var.tags

  lifecycle {
    # HARDEN-002 (run 1): the module's db_password default is empty, so a
    # create_rds = true apply used to send an empty master password to AWS and
    # fail the whole run with "InvalidParameterValue: Invalid master password"
    # *after* the cluster had already been built. Fail here instead, where the
    # message can name the real fix, and independently of which caller runs
    # terraform. Evaluated at plan time, so an unusable password is reported
    # before anything is created.
    precondition {
      condition = (
        length(var.db_password) >= 8
        && !strcontains(var.db_password, "/")
        && !strcontains(var.db_password, "@")
        && !strcontains(var.db_password, "\"")
      )
      error_message = "db_password must be at least 8 characters and must not contain /, @ or a double quote (RDS master-password rules) when create_rds = true. Supply it out of band from your secret store, e.g. TF_VAR_db_password=... -- never with -var, because Sol records the terraform command line in its run log."
    }
  }
}

# ── Managed resource dashboards (CloudWatch) — OBS-044 ───────────────────── #
#
# "Managed resource dashboard" tier (docs/architecture/observability-design.md,
# "Dashboard Shape"): a CloudWatch-backed dashboard for AWS-managed
# datastores Sol provisions directly (RDS today), so an operator never has
# to leave Sol for the raw AWS console to see CPU/connections/storage/IOPS.
#
# Generic by resource type, not RDS-specific: local.managed_resources is a
# name -> {resource_type, cloudwatch_namespace, dimension_name,
# dimension_value, metrics} map. Adding a future managed datastore this
# layer provisions (e.g. DynamoDB, if that's ever added -- it isn't today,
# see OBS-044's acceptance criteria) means adding another entry to this map
# and to the CloudWatch IAM policy's namespace coverage, not a second
# one-off dashboard implementation. platform/cloud/modules/platform reads the
# managed_resource_dashboards output below (same manual cross-state `-var`
# wiring already used for loki_s3_bucket/thanos_irsa_arn) to provision one
# Grafana dashboard per resource_type from a single shared template
# (dashboards/managed-resource.json.tftpl) plus a CloudWatch datasource.
# `sol open dashboard resource/<type>/<name>` (cli/lib/deploy/sol_cli_open.ml)
# resolves the matching Grafana URL by that same resource_type value.
locals {
  managed_resources = var.create_rds ? {
    postgres = {
      resource_type        = "rds"
      cloudwatch_namespace = "AWS/RDS"
      dimension_name       = "DBInstanceIdentifier"
      dimension_value      = aws_db_instance.postgres[0].identifier
      metrics              = ["CPUUtilization", "DatabaseConnections", "FreeStorageSpace", "ReadIOPS", "WriteIOPS"]
    }
  } : {}
}

# Native CloudWatch dashboard per managed resource -- usable standalone (e.g.
# straight from the AWS console during an incident) even though the primary
# surface is the Grafana dashboard platform/cloud/modules/platform provisions from the
# same local.managed_resources data via the managed_resource_dashboards
# output below.
resource "aws_cloudwatch_dashboard" "managed_resource" {
  for_each       = local.managed_resources
  dashboard_name = "${var.cluster_name}-${each.key}"

  dashboard_body = jsonencode({
    widgets = [
      for i, metric in each.value.metrics : {
        type   = "metric"
        x      = (i % 2) * 12
        y      = floor(i / 2) * 6
        width  = 12
        height = 6
        properties = {
          title   = metric
          region  = var.region
          stat    = "Average"
          period  = 300
          metrics = [[each.value.cloudwatch_namespace, metric, each.value.dimension_name, each.value.dimension_value]]
        }
      }
    ]
  })
}

# Grafana's own pod needs read access to CloudWatch to run the managed-
# resource dashboard's queries directly (unlike the Loki/Thanos IRSA roles
# above, which are consumed by their own pods, not Grafana's). Scoped to
# Grafana's documented minimal CloudWatch-datasource policy (metrics only --
# no logs:* since nothing here uses CloudWatch Logs Insights); CloudWatch's
# read APIs don't support resource-level ARN scoping, hence "*".
data "aws_iam_policy_document" "grafana_cloudwatch" {
  count = length(local.managed_resources) > 0 ? 1 : 0

  statement {
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:DescribeAlarmsForMetric",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "grafana_cloudwatch" {
  count  = length(local.managed_resources) > 0 ? 1 : 0
  name   = "${var.cluster_name}-grafana-cloudwatch"
  policy = data.aws_iam_policy_document.grafana_cloudwatch[0].json
}

module "grafana_irsa" {
  count   = length(local.managed_resources) > 0 ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-grafana"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # Chart default ServiceAccount name for helm_release.grafana in
      # platform/cloud/modules/platform -- "grafana" release name -> "grafana" SA,
      # confirmed via `helm template grafana grafana-community/grafana
      # --version 13.2.1`.
      namespace_service_accounts = ["monitoring:grafana"]
    }
  }

  role_policy_arns = {
    grafana_cloudwatch = aws_iam_policy.grafana_cloudwatch[0].arn
  }
}

# ── Route53 ───────────────────────────────────────────────────────────────── #

resource "aws_route53_zone" "main" {
  name  = var.base_domain
  count = var.create_route53_zone ? 1 : 0
  tags  = var.tags
}

# ── cert-manager IRSA ─────────────────────────────────────────────────────── #
# IAM role + policy that allows the cert-manager pod to solve DNS01 challenges
# via Route53, enabling wildcard certificates.

data "aws_iam_policy_document" "cert_manager" {
  statement {
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
  statement {
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = var.create_route53_zone ? [aws_route53_zone.main[0].arn] : ["arn:aws:route53:::hostedzone/*"]
  }
  statement {
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cert_manager" {
  name   = "${var.cluster_name}-cert-manager"
  policy = data.aws_iam_policy_document.cert_manager.json
}

module "cert_manager_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-cert-manager"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  role_policy_arns = {
    cert_manager = aws_iam_policy.cert_manager.arn
  }
}

# HARDEN-002 run 2, finding 7: the EBS CSI driver's identity. Scoped to the
# driver's own service account, so no workload can use it to reach EBS.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  # The module would otherwise name this policy AmazonEKS_EBS_CSI_Policy-<suffix>.
  # Every identity in this file is cluster-scoped (see aws_iam_policy.cert_manager),
  # and the scoped provisioner identity may only create iam:*/${cluster_name}* --
  # so the default name is one the provisioner that applies this cannot create.
  policy_name_prefix = "${var.cluster_name}-"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn

  depends_on = [module.eks]
}

# ── Durable observability storage (OBS-006 logs, OBS-007 metrics) ─────────── #
#
# Bucket/role names are predictable (${cluster_name}-...) so
# platform/cloud/modules/platform's observability_backend = "self_hosted_durable" can
# reference them via plain -var flags. Same manual-wiring pattern as
# cert_manager_irsa_role_arn above — these are separate Terraform states with
# no automatic remote-state linking; see this module's outputs.

resource "aws_s3_bucket" "loki" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = "${var.cluster_name}-loki-logs"
  tags   = var.tags

  # INFRA-037: this bucket's contents are produced by running the platform (Loki
  # and Thanos ship into it), so a target that has run for any length of time can
  # never be destroyed while it is non-empty. [prevent_destroy] made that worse
  # than a failure: terraform refuses before it even attempts the delete, so
  # `sol cloud destroy` could never complete for a durable-observability target
  # and the infrastructure was stranded. See ADR 0004.
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = aws_s3_bucket.loki[0].id

  rule {
    id     = "expire-old-chunks"
    status = "Enabled"
    filter {}
    expiration {
      days = var.loki_retention_days
    }
  }
}

data "aws_iam_policy_document" "loki_s3" {
  count = var.enable_durable_observability ? 1 : 0
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki[0].arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki[0].arn}/*"]
  }
}

resource "aws_iam_policy" "loki_s3" {
  count  = var.enable_durable_observability ? 1 : 0
  name   = "${var.cluster_name}-loki-s3"
  policy = data.aws_iam_policy_document.loki_s3[0].json
}

module "loki_irsa" {
  count   = var.enable_durable_observability ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-loki"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["monitoring:loki"]
    }
  }

  role_policy_arns = {
    loki_s3 = aws_iam_policy.loki_s3[0].arn
  }
}

resource "aws_s3_bucket" "thanos" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = "${var.cluster_name}-thanos-metrics"
  tags   = var.tags

  # INFRA-037: this bucket's contents are produced by running the platform (Loki
  # and Thanos ship into it), so a target that has run for any length of time can
  # never be destroyed while it is non-empty. [prevent_destroy] made that worse
  # than a failure: terraform refuses before it even attempts the delete, so
  # `sol cloud destroy` could never complete for a durable-observability target
  # and the infrastructure was stranded. See ADR 0004.
  force_destroy = true
}

data "aws_iam_policy_document" "thanos_s3" {
  count = var.enable_durable_observability ? 1 : 0
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.thanos[0].arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.thanos[0].arn}/*"]
  }
}

resource "aws_iam_policy" "thanos_s3" {
  count  = var.enable_durable_observability ? 1 : 0
  name   = "${var.cluster_name}-thanos-s3"
  policy = data.aws_iam_policy_document.thanos_s3[0].json
}

module "thanos_irsa" {
  count   = var.enable_durable_observability ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-thanos"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "monitoring:prometheus-server",
        "monitoring:thanos-storegateway",
        "monitoring:thanos-compactor",
      ]
    }
  }

  role_policy_arns = {
    thanos_s3 = aws_iam_policy.thanos_s3[0].arn
  }
}
