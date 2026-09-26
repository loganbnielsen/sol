output "state_bucket" {
  description = "The provisioned state bucket. Declare it as `state_bucket` on the target; Sol derives the rest of the backend (`prefix=sol/<cloud|platform>/<target>.tfstate`) from the target itself."
  value       = google_storage_bucket.state.name
}

output "target_field" {
  description = "The target declaration this root exists to satisfy, in the shape the target file takes."
  value       = "target:\n  state_bucket: ${google_storage_bucket.state.name}"
}

output "dns_zone_name" {
  description = "The durable qualification DNS zone this root owns, if any. The registrar delegation must outlive every target."
  value       = var.manage_dns_zone ? google_dns_managed_zone.qualification[0].name : null
}

output "dns_zone_nameservers" {
  description = "The zone's authoritative nameservers — read this from the durable owner, not from a target's plan, so the values cannot drift from the delegation."
  value       = var.manage_dns_zone ? google_dns_managed_zone.qualification[0].name_servers : null
}
