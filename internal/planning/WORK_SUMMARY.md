# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: GCP Attempt 12 — the RBAC collision is gone, the SSD quota is the new frontier (2026-09-26)

- Ran a fresh target at `main @ cf43aaee` (cluster `sol-qual-gcp-12`, its own state key). **FND-0061 is `QUALIFIED` live**: `platform-prerequisites-apply` and the full `platform-apply` both passed the boundary that failed Attempt 11, with no `already exists` anywhere, and the install continued into its Helm releases for 22 minutes.
- The new blocker is the environment, not the lifecycle: the observability PVCs (`storage-loki-0` 10Gi, `prometheus-server` 8Gi, `alertmanager` 2Gi) never bind — `CreateVolume failed … (QUOTA_EXCEEDED): Quota 'SSD…'` — because `SSD_TOTAL_GB` reads **limit 500 / usage 500** with five Autopilot nodes at 100 GiB boot disks each, and **usage 0** after teardown. Filed as **FND-0062 / INFRA-090** (BACKLOG).
- The preflight said the quota was fine: its probe measures the cluster's Autopilot CPU/memory budget, not regional disk quota. INFRA-090 adds that probe so the next run refuses in five seconds instead of failing in 43 minutes.
- Supported destruction from the failed install ran clean again: `platform-destroy ok (135.4s)`, substrate `346.6s`, both roots empty, provider inventory absent, durable prerequisites intact, no manual action.
