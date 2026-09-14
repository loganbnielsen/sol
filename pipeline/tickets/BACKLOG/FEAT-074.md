---
id: FEAT-074
type: feature
severity: medium
source: FEAT-066 review, 2026-09-14 — one-directional verification
---

Reconcile the desired workload set: prune live Sol-owned workloads a release does not contain

**Description:** `sol deploy`/`sol up` apply the plan's workloads but never delete a workload a previous release created and the current one no longer contains (a removed or renamed service). `sol rollback` (FEAT-066) now *detects* this — `Sol_cli_rollback.verify_workloads` compares the live Sol-owned workload set against the restored record's set and fails loudly on an unexpected object — but deliberately does not prune. Safe deletion (Deployments/Rollouts/CronJobs, their PVCs, Services/Ingress, ordering, shared resources, controller ownership) is a much larger feature than "restore a recorded release", so it was kept out of the rollback slice.

Consequence today: rolling `r-B = [payments, users, fraud]` back to `r-A = [payments, users]` re-applies r-A's workloads, then fails verification because `fraud` (r-B) is still running. The rollback is honest — the pointer is not moved and no false success is claimed — but it cannot complete a release that removed a workload.

**Impact:** An operator cannot roll a release back across a workload add/remove; they get a correct refusal and must delete the stale object by hand. Forward deploys carry the same un-pruned drift, silently, since nothing reports surplus workloads today.

**Remediation:** Design one `reconcile desired workload set` primitive that both deploy and rollback call: enumerate the live Sol-owned workloads for the workspace (reuse `Sol_cli_rollback.live_workloads`), diff against the desired set, and delete the surplus with explicit ownership checks and an order that does not orphan shared resources. Once it exists, rollback should prune as part of the recorded transition and deploy should adopt it (or at least report) separately. Do not add a one-off deletion path inside rollback.
