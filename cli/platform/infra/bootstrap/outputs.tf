output "backend_config" {
  description = "The `backend \"s3\"` block body for the target's Terraform. Record state_bucket/state_lock_table in the target file so preflight can verify them."
  value       = "bucket=${aws_s3_bucket.state.id}\nkey=sol/terraform.tfstate\nregion=${var.region}\ndynamodb_table=${aws_dynamodb_table.lock.name}\nencrypt=true"
}

output "state_bucket" {
  description = "The provisioned state bucket (declare as `state_bucket` on the target)."
  value       = aws_s3_bucket.state.id
}

output "state_lock_table" {
  description = "The provisioned lock table (declare as `state_lock_table` on the target)."
  value       = aws_dynamodb_table.lock.name
}

output "provisioner_policy_json" {
  description = "The generated provisioning-identity policy contract. The operator creates the role and supplies its ARN as `provisioner_role_arn`."
  value       = data.aws_iam_policy_document.provisioner.json
}

output "deploy_policy_json" {
  description = "The generated deploy-identity policy contract (no infrastructure or IAM mutation). Supply the role ARN as `deploy_role_arn`."
  value       = data.aws_iam_policy_document.deploy.json
}

output "publisher_policy_json" {
  description = "The generated publisher-identity policy contract (ECR image push only, no infrastructure/IAM/repository-lifecycle mutation). No target field consumes this ARN -- attach it to whatever identity your CI pipeline's own `docker push` authenticates as, before it calls `sol deploy` with the resulting digest."
  value       = data.aws_iam_policy_document.publisher.json
}

output "operator_policy_json" {
  description = "The generated operator-identity policy contract. Supply the role ARN as `operator_role_arn`."
  value       = data.aws_iam_policy_document.operator.json
}
