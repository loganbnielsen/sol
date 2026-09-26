# The shared definition's outputs, passed through unchanged. `sol cloud`
# reports them for the target it just converged.

output "argocd_url" {
  description = "Argo CD UI URL"
  value       = module.platform.argocd_url
}

output "grafana_url" {
  description = "Grafana UI URL"
  value       = module.platform.grafana_url
}

output "kafka_bootstrap" {
  description = "In-cluster Kafka bootstrap address for Sol services"
  value       = module.platform.kafka_bootstrap
}

output "schema_registry_url" {
  description = "In-cluster schema registry URL for Sol services"
  value       = module.platform.schema_registry_url
}

output "loki_url" {
  description = "In-cluster Loki push URL for Sol services"
  value       = module.platform.loki_url
}

output "pushgateway_url" {
  description = "In-cluster Prometheus Pushgateway URL for Sol services"
  value       = module.platform.pushgateway_url
}
