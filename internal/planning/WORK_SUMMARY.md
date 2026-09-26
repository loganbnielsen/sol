# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: INFRA-090 — the disk-quota precondition, checked where it means something (2026-09-26)

- The invariant is the operator's, and the code follows it exactly: **observation** (provider's regional `SSD_TOTAL_GB` limit/usage, read after the cloud infrastructure exists), **declaration** (`Sol_cli_platform_storage`: 20 GiB across prometheus server, alertmanager and loki), **policy** (`Sol_cli_disk_quota.sufficient`, in the apply sequence right after `cloud_ready`), and **no model of Autopilot's node behaviour** — the footprint is whatever the cluster has already made, which is why Attempt 12's pre-cloud 0/500 reading was useless.
- Placement is the lesson of Attempt 12: too early reads 0 usage, too late means the volumes are already asked for. The check sits between them, and an unreadable quota fails closed.
- The harness records the same quota independently and now classifies a provider `CreateVolume … QUOTA_EXCEEDED` refusal as `PROVIDER_DISK_QUOTA_EXCEEDED`, ahead of ambient pod symptoms. A successful install also captures the provisioner bindings, closing FND-0061's last inference.
- `check_platform_storage_requirement.sh` keeps the declaration honest against the module (its first catch was this ticket's author claiming a size Sol does not set — `prometheus_persistent_storage` is a bool).
- **Qualification project: `SSD_TOTAL_GB` 500 → 1000 GiB, confirmed effective.** FND-0062 is `FIXED_UNQUALIFIED`; the next live run is the discriminator.
