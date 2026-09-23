# Disposable GCP cloud-root shape for a qualification attempt (HARDEN-004).
#
# NOT for real workspaces. Mirrors internal/qualification/aws/smoke-test.tfvars:
# the smallest shape that can run the base platform stack, with every knob that
# turns a "cheap attempt" into an orphaned bill set so it cannot be forgotten.
#
# Usage (through the harness, which supplies the per-run values):
#   internal/qualification/gcp/live-qual.sh cloud
#
# Deliberately NOT set here, because they are per run and must be named explicitly:
#
#   cluster_name             — pick a unique one per run; a reused name collides
#                              with the previous run's state and surviving DNS zone.
#   db_password              — generated per run by the harness.
#   provisioner_impersonators — the identity allowed to impersonate the provisioner
#                              for the install window; an account-specific string, so
#                              it is never committed.
#
# `base_domain` IS set here, because it is the delegated name DEC-042 fixed and the
# whole point of the attempt is to exercise the real public-TLS path under it.

project_id = "sol-qualification"
region     = "us-central1"

# DEC-042: qual-gcp.sol-fab.dev, one delegated label per cloud. The zone is created
# by this cloud root (google_dns_managed_zone.main) and its `dns_nameservers` output
# is what gets pasted at Squarespace. The zone is a durable prerequisite, not part of
# the disposable substrate: the harness's absent-verification expects it to SURVIVE
# teardown, because a recreated zone gets new nameservers and silently invalidates
# the delegation.
base_domain = "qual-gcp.sol-fab.dev"

# DEC-043: the delegated zone is a durable prerequisite whose registrar delegation lives
# outside every provider API, so it is owned by cli/platform/infra/bootstrap-gcp, not by
# the disposable cloud root. Two roots must never manage one zone, so this is false here.
# (Before DEC-043 this root created the zone; Attempt 5 showed what that costs when the
# target that owns it is destroyed.)
create_dns_zone = false

# The platform stack the attempt is trying to install (cert-manager, ingress, Argo CD,
# Redpanda, Loki/Grafana, Prometheus) fits the defaults; no durable object storage is
# qualified by this attempt, so it stays off — it is a separate HARDEN-004 row and
# would leave buckets behind for nothing.
enable_durable_observability = false

# Cloud SQL: not the row under test, and the target omits the Postgres resource, so
# Sol derives its absence from the merged config. Kept minimal and disposable.
sql_tier            = "db-g1-small"
sql_disk_gb         = 20
sql_high_availability = false

# CRITICAL — the defaults are `true` for both, which is correct for production and
# fatal for a disposable attempt: a destroy that refuses (GKE deletion protection) or
# strands a final snapshot (Cloud SQL) is exactly how an attempt becomes a bill nobody
# notices. `sol cloud destroy` also lowers GKE's flag for its Destroy phase, but
# stating it here keeps this file a complete picture of the attempt's shape.
gke_deletion_protection = false
sql_deletion_protection = false
