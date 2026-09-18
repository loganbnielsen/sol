---
id: CODE_LAYER-016
type: code-layer-finding
severity: medium
source: pipeline/audits/2026-09-09_code_layer_audit.md
---

# Model per-workload persistent volumes in the deployment plan

Platform component persistence exists, but application services/workers/fns have
no typed way to request a mounted persistent volume.

Add a narrow `sol.toml` model and deployment-plan field for named volumes:
`mount_path`, `size`, and `access_mode`. Render a PVC plus container
`volumeMount`/pod `volumes` for services and workers. Keep StorageClass,
snapshots, backups, and RWX policy out of scope.

Acceptance:
- `Sol_cli_toml` parses and validates `[infra.volumes.<name>]`.
- `Sol_cli_deployment_plan.service_spec` carries volumes.
- Manifest rendering emits PVC + mounts.
- Tests cover service and worker rendering.
