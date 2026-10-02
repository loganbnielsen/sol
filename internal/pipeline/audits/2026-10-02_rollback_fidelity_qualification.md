# Rollback fidelity qualification — 2026-10-02

Scope: `sol rollback` / `sol local rollback` against `main` at
`54f53c8e0d58aa0511b86f46debc154de102589e`. The question: can a previous release
actually be restored after a bad deployment — artifacts and configuration
included — through partial/interrupted failures, without ever restoring or
overwriting independently managed secret values?

## Evidence class

**Not a live behavioural run.** This environment cannot run one: `kubectl` is
not installed, `docker` resolves to the Windows client with WSL integration off
(no `/var/run/docker.sock`), and `k3d` cannot reach a daemon. That is the same
constraint `DEC-029` recorded for its P1–P8 experiment on 2026-10-02, and it is
why `VERIF-020`/`VERIF-021` are gated on operator authorization.

What this run provides is **repository-derived plus modelled-cluster
behavioural** evidence: the real `Sol_cli_rollback.execute` transaction, the real
`Sol_cli_release.service_specs_of_release` reconstruction, the real
`Sol_cli_deployment_render.render_spec`, and the real `Sol_cli_release_id`
projection are exercised, with only the Kubernetes API server replaced by a
stateful in-process model. It is stronger than a call-order unit test and weaker
than a live cluster. A live rollback row remains open.

## Method

A stateful model of the cluster (workloads with release labels, the
current-release pointer, the live Secret, the manifests each apply rendered) is
driven through the real transaction, so the assertions are about the state a
rollback leaves behind rather than which callbacks it invoked:

- **Restore after a bad deploy.** Seed the model at a bad release, add a surplus
  workload, put real values in the live Secret, then roll back to the target
  release. Assert the workloads carry the restored label, the pointer names the
  restored release, the surplus workload is pruned, every workload is re-rendered
  through the real renderer, and the live Secret is byte-identical afterwards.
- **Partial apply.** Fail the apply of the second workload after the first has
  been applied. Assert the transaction fails, the pointer still names the bad
  release, and the live Secret is untouched.
- **Secret-material invariant.** Render a reconstructed workload whose recorded
  secret entry carries material. Assert the rendered manifests carry no
  `kind: Secret`, no `stringData`, no material, and still reference the key
  (`secretKeyRef`).
- **Interrupted failure / concurrency.** Re-confirmed against the existing
  transaction tests: lost lease after apply and after prune leaves the pointer
  unmoved (`BUG-071`), unreadable applied state skips every mutation (`BUG-078`),
  a prune failure skips the pointer move, a workload/verifier mismatch skips
  prune and the pointer move.

## Result

| Invariant | Verdict |
|---|---|
| A bad deploy is restored: workloads re-labelled, pointer moved, surplus pruned, config/image re-rendered | PASS |
| A partial apply fails closed: pointer unmoved, no prune, Secret untouched | PASS |
| An interrupted rollback (lost lease) leaves the pointer unmoved | PASS (existing tests) |
| Rollback never restores or overwrites secret values; renders references only | PASS |
| The restored artifact equals the artifact that was deployed | **FAIL — owned by FEAT-096** |

## Findings

- **Readiness drift is real but already owned.** The release record never
  captured the workload language; reconstruction sets `language = None`, and
  `Sol_cli_deployment_render` derives the readiness probe from it, so a restored
  OCaml service gets `readinessProbe.path: /healthz` instead of the `/readyz` it
  was deployed with (TypeScript is unaffected). This is a symptom of the
  language-dependent readiness exception that `FEAT-096` was promoted to remove
  on 2026-10-02 ("drop the TypeScript exception in `Sol_cli_deployment_render`
  (the `readiness_path` match)"). Once readiness is language-independent the
  reconstruction reproduces the probe without the record carrying a language, so
  this run files no competing fix — it names FEAT-096 as the owner. Until
  FEAT-096 lands, a rollback of an OCaml `-svc` still weakens its shutdown
  semantics.
- **BUG-118 (medium).** `Sol_cli_rollback.decode_workload` parses the recorded
  `availability` leniently: an unparseable value silently becomes `Single`,
  dropping a `node-failure-tolerant` workload's PDB on restore instead of failing
  closed. Every sibling decode in the same function fails closed.
- **BUG-119 (low).** A partial-apply failure returns the raw apply error without
  stating that the pointer was left unchanged and the cluster is partway
  restored, unlike every other failure branch of the transaction.
- **BUG-120 (medium, needs a decision).** `prune_workloads` removes only the
  surplus `Deployment`/`Rollout`/`CronJob`; the removed workload's `Service`,
  `<name>-env` ConfigMap, ServiceAccount, NetworkPolicy, PDB and PVCs are left
  behind. Whether PVCs may be deleted is a storage-lifetime decision.

## Limitations

- No real API server, so server-side validation, RBAC boundaries, admission,
  controller reconciliation and readiness are not observed. A live rollback run
  is still required before the production behavioural claim is satisfied.
- The model reproduces the transaction's own contract; it does not independently
  prove that a real `kubectl apply` of the rendered manifests produces the
  asserted cluster state.
