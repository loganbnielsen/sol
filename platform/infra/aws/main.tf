# platform/infra/aws — AWS cluster provisioning for Sol workspaces
#
# Provisions:
#   VPC            — public + private subnets across 3 AZs, NAT gateway
#   EKS            — managed cluster with a general-purpose node group
#   ECR            — one repository per service name (list in variables)
#   RDS PostgreSQL — managed database (replaces in-cluster postgres)
#   Route53 zone   — base domain for Ingress / cert-manager
#
# After apply: run platform/infra/base/ to install platform components.
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

  # Uncomment to store state in S3 (recommended for teams):
  # backend "s3" {
  #   bucket = "my-terraform-state"
  #   key    = "sol/prod/terraform.tfstate"
  #   region = "us-east-1"
  # }
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

  # Allow cluster creator admin access
  enable_cluster_creator_admin_permissions = true

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
  deletion_protection     = var.rds_deletion_protection
  skip_final_snapshot     = !var.rds_deletion_protection

  tags = var.tags
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
# one-off dashboard implementation. platform/infra/base reads the
# managed_resource_dashboards output below (same manual cross-state `-var`
# wiring already used for loki_s3_bucket/thanos_irsa_arn) to provision one
# Grafana dashboard per resource_type from a single shared template
# (dashboards/managed-resource.json.tftpl) plus a CloudWatch datasource.
# `sol open dashboard resource/<type>/<name>` (cli/sol/lib/sol_cli_open.ml)
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
# surface is the Grafana dashboard platform/infra/base provisions from the
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
      # platform/infra/base -- "grafana" release name -> "grafana" SA,
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

# ── Durable observability storage (OBS-006 logs, OBS-007 metrics) ─────────── #
#
# Bucket/role names are predictable (${cluster_name}-...) so
# platform/infra/base's observability_backend = "self_hosted_durable" can
# reference them via plain -var flags. Same manual-wiring pattern as
# cert_manager_irsa_role_arn above — these are separate Terraform states with
# no automatic remote-state linking; see this module's outputs.

resource "aws_s3_bucket" "loki" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = "${var.cluster_name}-loki-logs"
  tags   = var.tags

  lifecycle {
    prevent_destroy = true
  }
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

  lifecycle {
    prevent_destroy = true
  }
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
