terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ── AUDIT-072: the conformant remote state backend ─────────────────────────
#
# Sol provisions this by default; an operator may bring an equivalent backend
# (encrypted, versioned, locked) and declare it in the target file instead.
# This root is separate from platform/cloud/aws/cluster because a Terraform
# configuration cannot create its own backend: run this once, record the
# bucket/table in the target, and configure the backend there.

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The lock table serializes concurrent infrastructure mutations: two applies
# either serialize or one is rejected, without corrupting state.
resource "aws_dynamodb_table" "lock" {
  name         = var.state_lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ── AUDIT-072: IAM policy contracts ────────────────────────────────────────
#
# Sol generates the contracts; the operator creates the roles and supplies their
# ARNs in the target file. Sol does not manage role lifecycle. These documents
# are a least-privilege starting point: tighten resource ARNs to the account
# before use, and note the boundary they encode — the deploy identity may not
# mutate infrastructure or grant itself administrative access.

data "aws_iam_policy_document" "provisioner" {
  statement {
    sid    = "ManageClusterInfrastructure"
    effect = "Allow"
    actions = [
      "ec2:*",
      "eks:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "cloudwatch:*",
      "logs:*",
      "route53:*",
      "rds:*",
      "dynamodb:*",
      "s3:*",
      # Repository *lifecycle* only (platform/cloud/aws/cluster's aws_ecr_repository
      # resources are part of the substrate this identity already reconciles) --
      # never the data-plane actions that would let it publish an image. See the
      # explicit deny below: ADR 0002 states "provisioner must not publish
      # images" as a boundary, not merely an omission.
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:PutImageScanningConfiguration",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # HARDEN-002 finding 6 / ADR 0002: the provisioner creates the ECR
  # repositories but must never be the identity that publishes into them --
  # that is the publisher identity's job (see data.aws_iam_policy_document.publisher
  # below). An explicit deny makes this a structural boundary rather than an
  # absence that a future broader policy attachment could silently restore.
  statement {
    sid    = "NoImagePublish"
    effect = "Deny"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["*"]
  }
}

# DEC-034 / INFRA-046: cloud provisioning and steady-state cluster access are
# separate identities. This policy permits only discovery and credential
# retrieval for the EKS cluster. Kubernetes RBAC supplies the scoped platform
# authorization; explicit denies ensure this identity cannot create or mutate
# its own EKS access entry/policy association or any IAM identity.
data "aws_iam_policy_document" "cluster_access" {
  statement {
    sid       = "DiscoverCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]
  }

  statement {
    sid    = "NoAccessOrIdentityMutation"
    effect = "Deny"
    actions = [
      "eks:CreateAccessEntry",
      "eks:DeleteAccessEntry",
      "eks:UpdateAccessEntry",
      "eks:AssociateAccessPolicy",
      "eks:DisassociateAccessPolicy",
      "iam:*",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "LocateTheCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]
  }

  # The deploy identity reaches the cluster through an EKS access entry scoped to
  # the namespaces it deploys; it holds no infrastructure or IAM authority.
  statement {
    sid    = "NoInfrastructureOrIdentityMutation"
    effect = "Deny"
    actions = [
      "ec2:*",
      "eks:CreateCluster",
      "eks:DeleteCluster",
      "eks:UpdateClusterConfig",
      "eks:CreateAccessEntry",
      "eks:AssociateAccessPolicy",
      "iam:*",
    ]
    resources = ["*"]
  }
}

# HARDEN-002 finding 6: the provisioner creates the workspace's ECR
# repositories, and FEAT-050 requires a published digest before deploy, but
# before this identity existed nothing in the contract could publish one --
# the provisioner is explicitly denied it above, and deploy only reads
# (LocateTheCluster). This is the fourth identity ADR 0002's table already
# names ("publisher: publish/replace application images; must not provision
# substrate or deploy workloads") but the bootstrap root never generated a
# contract for. `sol up` never uses this -- it is local-only and never
# touches AWS (cli/bin/cmd_up.ml: "Local-only -- no target concept"); a
# CI pipeline authenticates as this identity before its own `docker push`,
# entirely outside Sol's own execution, then calls `sol deploy` with the
# resulting digest. Sol therefore has no runtime code path that resolves this
# ARN -- there is deliberately no `publisher_role_arn` target field to match;
# this is a policy-generation contract only, same spirit as the other three.
data "aws_iam_policy_document" "publisher" {
  statement {
    sid    = "PublishWorkspaceImages"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["*"]
  }

  # Publishing an image must not also grant the power to provision substrate
  # or to deploy/replace a running workload (ADR 0002).
  statement {
    sid    = "NoProvisionOrDeploy"
    effect = "Deny"
    actions = [
      "ec2:*",
      "eks:*",
      "rds:*",
      "iam:*",
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:PutLifecyclePolicy",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "operator" {
  statement {
    sid       = "ReadClusterAndState"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters", "s3:GetObject", "s3:ListBucket"]
    resources = ["*"]
  }
}
