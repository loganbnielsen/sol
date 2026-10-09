# Stable interface for workspace-owned Terraform composed into this root.
# Keep the keys and their meanings provider-neutral across supported drivers.
locals {
  sol_target = {
    provider           = "gcp"
    region             = var.region
    cluster_name       = google_container_cluster.main.name
    cluster_endpoint   = google_container_cluster.main.endpoint
    network_id         = google_compute_network.main.id
    private_subnet_ids = [google_compute_subnetwork.main.id]
  }
}
