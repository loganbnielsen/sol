output "state_bucket" {
  description = "The provisioned state bucket. Declare it as `state_bucket` on the target; Sol derives the rest of the backend (`prefix=sol/<cloud|platform>/<target>.tfstate`) from the target itself."
  value       = google_storage_bucket.state.name
}

output "target_field" {
  description = "The target declaration this root exists to satisfy, in the shape the target file takes."
  value       = "target:\n  state_bucket: ${google_storage_bucket.state.name}"
}
