# ClusterIssuer resources for cert-manager.
# These are applied after cert-manager is running.
# Switch between letsencrypt-staging (testing) and letsencrypt-prod.

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt certificate notifications"
  type        = string
}

variable "cert_manager_irsa_role_arn" {
  description = "IAM role ARN for cert-manager DNS01 Route53 access (AWS only). Leave empty on GCP."
  type        = string
  default     = ""
}

resource "kubernetes_manifest" "letsencrypt_staging" {
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
              region = "us-east-1"
              # roleArn is only needed on AWS; cert-manager ignores it on GCP
              roleArn = var.cert_manager_irsa_role_arn != "" ? var.cert_manager_irsa_role_arn : null
            }
          }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "letsencrypt_prod" {
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
              region  = "us-east-1"
              roleArn = var.cert_manager_irsa_role_arn != "" ? var.cert_manager_irsa_role_arn : null
            }
          }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}
