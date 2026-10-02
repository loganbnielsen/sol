variable "region" {
  description = "Region the target's environment runs in; scopes the secrets, database and Kafka ARNs the workload boundary permits."
  type        = string
}

variable "environment" {
  description = "Environment whose workload roles this reconciler owns and whose name scopes the role path and the permissions boundary."
  type        = string
}

variable "reconciler_trust_principal_arn" {
  description = "Principal permitted to assume the authorization reconciler role: the gated CI authorization job's own identity, never the deploy identity."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster whose pods these workload identities serve; scopes the pod identity associations. Empty declares no pod identity associations."
  type        = string
  default     = ""
}

variable "grants" {
  description = "The safe grant set Sol computed: only grants DEC-062 rule 4 permits the reconciler to establish. This is the generated input the reconciler feeds Terraform."
  type = list(object({
    unit       = string
    capability = string
    resource   = string
    namespace  = string
  }))
  default = []
}
