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
# This root is separate from cli/platform/infra/aws because a Terraform
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

data "aws_iam_policy_document" "operator" {
  statement {
    sid       = "ReadClusterAndState"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters", "s3:GetObject", "s3:ListBucket"]
    resources = ["*"]
  }
}
