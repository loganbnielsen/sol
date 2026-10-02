variable "project_id" {
  description = "Project the target's environment runs in; scopes every grant the reconciler may set."
  type        = string
}

variable "region" {
  description = "Region the target's environment runs in."
  type        = string
}

variable "environment" {
  description = "Environment whose secret grants this reconciler owns and whose name scopes them."
  type        = string
}

variable "reconciler_trust_principal" {
  description = "Principal permitted to impersonate the reconciler service account: the gated CI authorization job's own identity, never the deploy identity."
  type        = string
}
