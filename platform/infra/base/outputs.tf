output "argocd_url" {
  description = "Argo CD UI URL"
  value       = "https://argocd.${var.base_domain}"
}

output "grafana_url" {
  description = "Grafana UI URL"
  value       = "https://grafana.${var.base_domain}"
}

output "kafka_bootstrap" {
  description = "In-cluster Kafka bootstrap address for Sol services"
  value       = "redpanda.redpanda.svc.cluster.local:9093"
}

output "schema_registry_url" {
  description = "In-cluster schema registry URL for Sol services"
  value       = "http://redpanda.redpanda.svc.cluster.local:8081"
}

output "loki_url" {
  description = "In-cluster Loki push URL for Sol services"
  value       = "http://loki.monitoring.svc.cluster.local:3100"
}

output "pushgateway_url" {
  description = "In-cluster Prometheus Pushgateway URL for Sol services"
  value       = "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091"
}
