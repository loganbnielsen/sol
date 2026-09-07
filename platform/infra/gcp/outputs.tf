output "cluster_name" {
  value = google_container_cluster.main.name
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --region ${var.region} --project ${var.project_id}"
}

output "artifact_registry" {
  description = "Artifact Registry URL — pass as --registry to sol deploy"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.cluster_name}"
}

output "docker_auth_command" {
  description = "Command to authenticate Docker with Artifact Registry"
  value       = "gcloud auth configure-docker ${var.region}-docker.pkg.dev"
}

output "postgres_private_ip" {
  description = "Cloud SQL private IP (accessible from GKE pods)"
  value       = google_sql_database_instance.postgres.private_ip_address
  sensitive   = true
}

output "postgres_url" {
  description = "POSTGRES_URL for Sol services"
  value       = "postgresql://postgres:${var.db_password}@${google_sql_database_instance.postgres.private_ip_address}/app"
  sensitive   = true
}

output "dns_nameservers" {
  description = "Nameservers to set at your domain registrar"
  value       = var.create_dns_zone ? google_dns_managed_zone.main[0].name_servers : null
}
