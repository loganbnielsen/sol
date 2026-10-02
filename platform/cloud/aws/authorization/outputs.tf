output "reconciler_role_arn" {
  description = "The fenced reconciler role the gated authorization job assumes."
  value       = aws_iam_role.reconciler.arn
}

output "workload_role_path" {
  description = "IAM path every workload role for this environment must live under."
  value       = "/${local.role_path}"
}

output "permissions_boundary_arn" {
  description = "Boundary that must be attached to every workload role at creation."
  value       = aws_iam_policy.workload_boundary.arn
}
