variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt certificate notifications"
  type        = string
}

variable "cert_manager_irsa_role_arn" {
  description = "IAM role ARN cert-manager assumes to write Route 53 records (AWS only). From platform/cloud/aws/cluster's cert_manager_iam_role_arn output; empty on GCP, which supplies cert_manager_workload_identity_sa_email instead."
  type        = string
  default     = ""
}

variable "cert_manager_workload_identity_sa_email" {
  description = "GCP service account email cert-manager impersonates through Workload Identity to write Cloud DNS records (GCP only). From platform/cloud/gcp/cluster's cert_manager_workload_identity_sa_email output; empty on AWS, which supplies cert_manager_irsa_role_arn instead."
  type        = string
  default     = ""
}

variable "cert_manager_dns01_region" {
  description = "Region of the Route 53 endpoint cert-manager authenticates against (AWS only). Supplied by the AWS root as its own value rather than assumed here: the hosted zone is global, so this is an endpoint choice, not the cluster's region."
  type        = string
  default     = ""
}

variable "cert_manager_dns01_project" {
  description = "Project holding the Cloud DNS managed zone cert-manager writes challenge records into (GCP only). Supplied by the GCP root, which owns the zone."
  type        = string
  default     = ""
}

locals {
  cert_manager_identity = var.cloud_provider == "gcp" ? var.cert_manager_workload_identity_sa_email : var.cert_manager_irsa_role_arn

  cert_manager_identity_annotation = var.cloud_provider == "gcp" ? "iam.gke.io/gcp-service-account" : "eks.amazonaws.com/role-arn"

  cert_manager_identity_variable = var.cloud_provider == "gcp" ? "cert_manager_workload_identity_sa_email" : "cert_manager_irsa_role_arn"
}

resource "kubernetes_manifest" "letsencrypt_staging_aws" {
  count = var.cloud_provider == "gcp" ? 0 : 1

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-staging" }
    spec = {
      acme = {
        server              = "https://acme-staging-v02.api.letsencrypt.org/directory"
        email               = var.letsencrypt_email
        privateKeySecretRef = { name = "letsencrypt-staging" }
        solvers = [{
          dns01 = {
            route53 = {
              region  = var.cert_manager_dns01_region
              roleArn = var.cert_manager_irsa_role_arn != "" ? var.cert_manager_irsa_role_arn : null
            }
          }
        }]
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.cert_manager_irsa_role_arn != ""
      error_message = "cert-manager has no DNS-01 identity for aws: the aws root must supply ${local.cert_manager_identity_variable}, or every ACME challenge runs without credentials and no certificate can issue (FND-0067)."
    }
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "letsencrypt_prod_aws" {
  count = var.cloud_provider == "gcp" ? 0 : 1

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-prod" }
    spec = {
      acme = {
        server              = "https://acme-v02.api.letsencrypt.org/directory"
        email               = var.letsencrypt_email
        privateKeySecretRef = { name = "letsencrypt-prod" }
        solvers = [{
          dns01 = {
            route53 = {
              region  = var.cert_manager_dns01_region
              roleArn = var.cert_manager_irsa_role_arn != "" ? var.cert_manager_irsa_role_arn : null
            }
          }
        }]
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.cert_manager_irsa_role_arn != ""
      error_message = "cert-manager has no DNS-01 identity for aws: the aws root must supply ${local.cert_manager_identity_variable}, or every ACME challenge runs without credentials and no certificate can issue (FND-0067)."
    }
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "letsencrypt_staging_gcp" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-staging" }
    spec = {
      acme = {
        server              = "https://acme-staging-v02.api.letsencrypt.org/directory"
        email               = var.letsencrypt_email
        privateKeySecretRef = { name = "letsencrypt-staging" }
        solvers = [{
          dns01 = {
            cloudDNS = {
              project = var.cert_manager_dns01_project
            }
          }
        }]
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.cert_manager_workload_identity_sa_email != ""
      error_message = "cert-manager has no DNS-01 identity for gcp: the gcp root must supply ${local.cert_manager_identity_variable}, or every ACME challenge runs without credentials and no certificate can issue (FND-0067)."
    }
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "letsencrypt_prod_gcp" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-prod" }
    spec = {
      acme = {
        server              = "https://acme-v02.api.letsencrypt.org/directory"
        email               = var.letsencrypt_email
        privateKeySecretRef = { name = "letsencrypt-prod" }
        solvers = [{
          dns01 = {
            cloudDNS = {
              project = var.cert_manager_dns01_project
            }
          }
        }]
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.cert_manager_workload_identity_sa_email != ""
      error_message = "cert-manager has no DNS-01 identity for gcp: the gcp root must supply ${local.cert_manager_identity_variable}, or every ACME challenge runs without credentials and no certificate can issue (FND-0067)."
    }
  }

  depends_on = [helm_release.cert_manager]
}
