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

## Completion notes

- **The shared diff primitive**: `verify_workloads`'s `unexpected` computation
  was already exactly the surplus diff this ticket needed. Factored it out as
  `Sol_cli_rollback.unexpected_workloads ~expected ~live` (pure), and
  `verify_workloads` now calls it instead of inlining the same filter —
  one shared primitive, not two implementations that could disagree, per the
  ticket's own ask.
- **Rollback prunes, via FEAT-075's seam, not a one-off path.** Added
  `prune : (workload_identity * string) list -> (unit, string) result` to
  `transaction_deps` and a new `Sol_cli_rollback.prune_workloads ~ctx` that
  deletes each surplus workload's live object via `Sol_cli_kubectl.delete`.
  `execute` now: refuses outright on a mismatched or missing workload (unchanged
  from before — neither is fixable by deleting anything); otherwise calls
  `deps.prune` with whatever `unexpected` surplus verification found
  (possibly none), and only once that succeeds does the pointer move. A
  prune failure leaves the pointer unchanged, same failure shape as every
  other refusal in this sequence.
- **Ownership**: no additional check was needed beyond what already exists —
  every candidate for pruning came from `live_workloads`, which only
  enumerates objects carrying this workspace's own taxonomy label in the
  first place. **Ordering**: each deletion is independent (no object here
  owns another via `ownerReferences`), so there's no ordering hazard among
  surplus workloads to design around; every deletion is attempted even if
  one fails, so one failure doesn't leave unrelated surplus behind.
- **Deliberately narrow scope, and why**: pruning covers only the primary
  workload object — Deployment/Rollout/CronJob, the one kind
  `live_workloads`/`verify_workloads` already track. A removed service's
  other rendered objects (ConfigMap, Secret, PVC, Service, Ingress,
  NetworkPolicy, ServiceAccount — confirmed by grepping
  `sol_cli_manifest_yaml.ml`'s rendered kinds) are left alone. Automatically
  deleting a PVC risks real, irreversible data loss, and safely cleaning up
  the rest needs its own ownership/ordering design — genuinely the larger
  feature the original FEAT-066 ticket flagged as out of scope, not
  something to improvise here. This is a real, stated gap, not a silent one.
- **Deploy's side: report, never delete**, exactly per the ticket's hedge.
  `sol up` (`cmd_up.ml`) and `sol deploy` (`cmd_deploy.ml`) each gained a
  `report_surplus_workloads` that runs after a successful apply, reuses
  `unexpected_workloads`, and prints a note listing any surplus — but
  **only for a whole-workspace deploy** (`requested_scope = "workspace"`). A
  `--scope`d deploy's plan is a strict subset of the workspace, so comparing
  it against every live workload would flag out-of-scope services (never
  touched by this run) as false surplus; skipping the check there avoids
  that correctness bug rather than shipping a report that lies some of the
  time. Deploy never prunes: unlike rollback, it has no recorded release
  boundary backing "this is exactly what should exist", only what it was
  asked to deploy this run. Best-effort — a `live_workloads` failure is
  swallowed rather than failing an otherwise-successful deploy.
- **Tests**: `test_rollback.ml`'s `rollback_transaction` group gained four
  cases (a purely-unexpected workload triggers prune then completes; a prune
  failure blocks the pointer move; a missing workload and a label mismatch
  each still refuse outright without ever calling prune) and the old
  "workload mismatch skips pointer move" test — whose fixture was actually
  the pure-unexpected case, now exercising the new prune path — was replaced
  rather than left describing behavior that no longer exists. Full local
  suite (unit/kafka/e2e) passes; `dune fmt` clean.
- **Docs**: `docs/architecture/devops-pipeline.md`'s `sol rollback` section
  gained the new step 7 (prune) and a paragraph on `sol up`/`sol deploy`'s
  report-only counterpart.
- No demo/example update: this changes internal CLI reconciliation behavior,
  not a `sol.toml` field, CLI command, framework primitive, or generated
  manifest an app author writes against.
