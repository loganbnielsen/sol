terraform {
  required_version = ">= 1.6"

  backend "s3" {}

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

resource "aws_route53_zone" "qualification" {
  count = var.manage_dns_zone ? 1 : 0

  name = var.base_domain
}

resource "aws_route53_record" "delegation" {
  count = var.manage_dns_zone && var.parent_zone_id != "" ? 1 : 0

  zone_id = var.parent_zone_id
  name    = aws_route53_zone.qualification[0].name
  type    = "NS"
  ttl     = 172800
  records = aws_route53_zone.qualification[0].name_servers
}

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

resource "aws_dynamodb_table" "lock" {
  name         = var.state_lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

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
