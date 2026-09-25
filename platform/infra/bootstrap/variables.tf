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
