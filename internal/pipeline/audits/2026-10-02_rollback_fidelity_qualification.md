# Rollback fidelity qualification — 2026-10-02

Scope: `sol rollback` / `sol local rollback` against `main` at
`54f53c8e0d58aa0511b86f46debc154de102589e`. The question: can a previous
release actually be restored after a bad deployment — artifacts and
configuration included — through partial/interrupted failures, without ever
restoring or overwriting independently managed secret values?

## Evidence class

**Not a live behavioural run.** This environment cannot run one: `kubectl` is
not installed, `docker` resolves to the Windows client with WSL integration off
(no `/var/run/docker.sock`), and `k3d` cannot reach a daemon. That is the same
constraint `DEC-029` recorded for its P1–P8 experiment on 2026-10-02, and it is
why `VERIF-020`/`VERIF-021` are gated on operator authorization.

What this run does provide is **repository-derived plus modelled-cluster
behavioural** evidence: the real `Sol_cli_rollback.execute` transaction, the real
`Sol_cli_release.service_specs_of_release` reconstruction, the real
`Sol_cli_deployment_render.render_spec`, and the real
`Sol_cli_release_id` projection are exercised, with only the Kubernetes API
server replaced by a stateful in-process model. It is stronger than a call-order
unit test and weaker than a live cluster. A live row remains open and is tracked
as a follow-up ticket.

## Method

`cli/test/inline/test_rollback.ml`:

- **Restore after a bad deploy.** Seed a model at release `r-9999…` (two
  workloads at the bad label, the pointer on it, one surplus workload, a live
  secret carrying values). Run the real transaction against the target release.
  Assert the workloads carry the restored label, the pointer names the restored
  release, the surplus workload is pruned, each workload is re-rendered through
  the real renderer, and the live secret is byte-identical afterwards.
- **Partial apply.** Fail the apply of the second workload after the first has
  been applied. Assert the transaction fails, the pointer still names the bad
  release, only one workload was applied, and the live secret is untouched.
- **Secret-material invariant.** Render a reconstructed workload whose recorded
  secret entry carries material. Assert the rendered manifests contain no
  `kind: Secret`, no `stringData`, no material, and still reference the key
  (`secretKeyRef`).
- **Interrupted failure / concurrency.** Already covered by the existing
  transaction tests, re-confirmed green: lost lease after apply and after prune
  leaves the pointer unmoved (`BUG-071`), unreadable applied state skips every
  mutation (`BUG-078`), prune failure skips the pointer move, a workload/verifier
  mismatch skips prune and the pointer move.

## Result

`dune test cli/test/inline` — green.

| Invariant | Verdict |
|---|---|
| A bad deploy is restored: workloads re-labelled, pointer moved, surplus pruned, config/image re-rendered | PASS |
| A partial apply fails closed: pointer unmoved, no prune, secret untouched | PASS |
| An interrupted rollback (lost lease) leaves the pointer unmoved | PASS (existing tests) |
| Rollback never restores or overwrites secret values; renders references only | PASS |
| The restored artifact equals the artifact that was deployed | **FAIL — BUG-118** |

## Findings

- **BUG-118 (high, fixed on this branch).** The release record never captured the
  workload language, so reconstruction set `language = None` and every OCaml
  service was re-applied with `readinessProbe.path: /healthz` instead of the
  `/readyz` it was deployed with. TypeScript is unaffected. The pre-existing
  "render correctness" gate could not catch it because every fixture used
  `language = None`. Fixed by recording the language, extending the identity
  encoding additively (a language-less record rederives the id it recorded — the
  existing known-vector still passes), and reconstructing it.
- **BUG-119 (medium, filed).** `Sol_cli_rollback.decode_workload` parses the
  recorded `availability` leniently: an unparseable value silently becomes
  `Single`, dropping a `node-failure-tolerant` workload's PDB on restore instead
  of failing closed.
- **BUG-120 (low, filed).** A partial-apply failure returns the raw apply error
  without stating that the pointer was left unchanged and the cluster is
  partway restored, unlike every other failure branch of the transaction.
- **BUG-121 (medium, filed, needs a decision).** `prune_workloads` removes only
  the surplus `Deployment`/`Rollout`/`CronJob`; the workload's `Service`,
  `<name>-env` ConfigMap, ServiceAccount, NetworkPolicy, PDB and PVCs are left
  behind when a rollback drops a workload the bad deploy had added. Whether PVCs
  should be deleted is a storage-lifetime decision, so this is filed rather than
  fixed.

## Limitations

- No real API server, so server-side validation, RBAC boundaries, admission,
  controller reconciliation and readiness are not observed. A live rollback run
  is still required before the production behavioural claim is satisfied.
- The model reproduces the transaction's own contract; it does not independently
  prove that a real `kubectl apply` of the rendered manifests produces the
  asserted cluster state.
