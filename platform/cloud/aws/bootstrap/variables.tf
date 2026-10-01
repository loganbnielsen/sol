variable "region" {
  description = "AWS region for the state bucket and lock table."
  type        = string
}

variable "state_bucket" {
  description = "Globally-unique S3 bucket name for the encrypted, versioned Terraform state."
  type        = string
}

variable "state_lock_table" {
  description = "DynamoDB table name used for Terraform state locking."
  type        = string
}

variable "manage_dns_zone" {
  description = "Own the delegated qualification DNS zone from this durable root. Off by default: a project that has not delegated a zone has none to own."
  type        = bool
  default     = false
}

variable "parent_zone_id" {
  description = "The hosted zone that publishes this installation's domain, when that zone is in the same account. Sol observes it and passes the id so the durable root can write the NS delegation itself; empty means the operator adds the records at the zone they control."
  type        = string
  default     = ""
}

variable "base_domain" {
  description = "The delegated qualification name (e.g. qual-aws.sol-fab.dev). Required when manage_dns_zone is true."
  type        = string
  default     = ""
}
