---
id: INFRA-093
type: feature
severity: high
source: GCP qualification Attempt 14 (2026-09-26), DEC-049
---

# INFRA-093 — the GCP driver provisions GKE Standard, and the profile refuses Autopilot

**Depends on:** None.

Attempt 14 measured the mismatch (FND-0064): Autopilot's admission webhook refused
`helm_release.prometheus` (`hostNetwork`/`hostPID`) and `helm_release.redpanda`
(`linux capability 'SYS_RESOURCE' on container 'tuning'`) after the cloud root and the platform
prerequisites had been applied — ten minutes and one billable cluster, with no path to `Ready`.

**Decision (DEC-049):** GKE Standard is the supported GCP substrate for the standard Sol platform
profile, and node sizing is a driver-owned default rather than target configuration.

## What lands

1. The GCP cluster root provisions Standard: `enable_autopilot = false` (a literal, with no knob
   that could turn it back on), no leftover default pool, and a node pool Sol owns whose sizing
   comes from driver-declared variables (`node_count`, `node_machine_type`, `node_disk_gb`) with
   defaults. The control plane stays regional (`location = var.region`); the pool is pinned to one
   zone so the qualification topology is three nodes rather than nine.
2. `Sol_cli_cluster_substrate`: the support contract as a typed thing — Standard and a fresh target
   are acceptable, Autopilot is refused with a message about the *profile* (Autopilot's
   restrictions are the reason, not today's component list), and an unreadable cluster is `Unknown`
   and refused rather than read as absence.
3. `Sol_cli_gcp_cluster.substrate_of_describe`: a read-only observation of an existing cluster's
   mode, naming the project from the cloud root's own outputs.
4. The refusal runs in `Sol_cli_cloud_apply` **before the plan**, so an unsupported substrate costs
   no Terraform run at all.
5. `check_gcp_standard_substrate.sh` + mutations hold the contract without freezing today's
   numbers: it asserts *ownership* (driver variables, defaults) and never the specific sizing.

## Acceptance criteria

- The guard and its mutations pass; the offline lifecycle harness refuses an Autopilot target with
  **no `terraform plan`** in the log.
- `test_cluster_substrate` covers the contract and the tri-state observation; `test_cloud_apply`
  covers the refusal before the plan.
- A live attempt installs the platform on a Standard cluster and reaches `Ready` (Attempt 15).
