---
id: INFRA-051
type: bug
severity: low
title: Decide how release pruning reads the release set it may not list
source: audit finding FND-0014 — live AWS Run 8 step 6
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0014-release-pruning-lists-configmaps-it-may-not-list.md`

## The defect

Every successful deploy warns:

```text
warning: could not prune old releases: kubectl get configmap failed:
Error from server (Forbidden): configmaps is forbidden: … cannot list resource
"configmaps" in API group "" in the namespace "default"
```

Release records live in `default`, where the deploy identity holds a deliberately
narrow exception (`sol_boundary_lease`): `configmaps` with `create`, and with
`get`/`update`/`delete`. **`list` is absent by design.** Pruning is a discovery
operation — it asks which releases exist — so it is refused and silently skipped.

Not urgent: the deploy succeeds and the workload runs. But release records
accumulate unboundedly in `default`, and a rollback path the profile relies on
degrades with only a warning to show for it.

## First: choose the contract

Do not implement before deciding, because the two readings differ in kind:

- **Broaden the exception** to `list` on `configmaps` in `default`. Small, but it
  widens the boundary the RBAC file argues hardest for, and `list` cannot be
  name-scoped — the same limitation the file already documents for `create`.
- **Keep the boundary, change the mechanism**: read the release set where Sol can
  address it by name (the workspace Secret, or the boundary-lease ConfigMap it
  already owns), or make the skip a diagnosed outcome rather than a warning.

Record the choice as a `DEC` if it is a contract decision, then implement.

## Acceptance criteria

1. A deploy either prunes the release set it is entitled to see, or records
   explicitly that it did not and why — never a bare warning.
2. The deploy identity's grants are unchanged unless the decision above says
   otherwise, and `check_production_infra.sh` still pins them.
3. Whichever mechanism is chosen, the matrix has a row for it, so "pruning did not
   happen" is a qualification result rather than an unnoticed warning.

## Out of scope

The namespace/RBAC mismatch (`INFRA-048`) and the secret-backend default
(`INFRA-050`). This is the same INV-AUTH-6 shape, but a separate defect.

## Decision and completion (2026-10-02)

**Premise verified** on `origin/main @ f7d45074`: `Sol_cli_release_retention.prune`
still calls `Sol_cli_release_store.list_with_creation`, whose
`kubectl get configmap -n default -l …` is a `list`, and both call sites
(`cli/lib/deploy/sol_cli_deploy_run.ml:261`, `cli/bin/cmd_up.ml:259`) still report
its refusal as `warning: could not prune old releases`.

**Chosen contract.** The boundary-lease grant is **not** widened; the
deploy identity's discovery precondition is deliberately absent, so the deploy
reports retention as an explicit deferral rather than attempting a prune it
cannot perform. Manifestation 2 of `FND-0014` (the pointer that could not be
patched) is already resolved on `main` — `Sol_cli_release_store.write_json`
reads by name and then uses `create`/`replace`, matching the granted verbs.

The alternatives were rejected on the boundary's own terms: `list` cannot be
name-scoped, so granting it would expose every ConfigMap in `default` — the
exception `platform_deploy_rbac.tf` argues hardest for and
`check_production_infra.py` pins; and a deploy-maintained
`sol-release-index-<workspace>` ConfigMap would keep the boundary but add a
second source of truth that can drift from the records it indexes. If retention
becomes load-bearing rather than tidy-up, the index is the mechanism to build,
and this choice should be revisited then.

**Implementation**

- `Sol_cli_release_retention` asks `kubectl auth can-i list configmaps -n default`
  before pruning. `enumerability_of_can_i_output` maps `yes`/`no` to
  `Some true`/`Some false` and anything else to `None` (unverified, never a
  definite refusal).
- `with_retention` prunes when enumeration is permitted, returns
  `Deferred <reason>` when it is refused, and `Failed <msg>` for any other error.
- Both deploy call sites print `Retention: not run -- …` for the deferral
  (`Sol_cli_report.app` in `deploy_run`, `Printf.printf` in `cmd_up`); a genuine
  error still warns.
- Matrix row **B8** added to
  `internal/qualification/aws/production-single-region-v1-matrix.md`.

**Evidence**

- `dune build cli` clean.
- `dune test cli` — the release-retention suite passes with three new cases
  (`can-i: yes`/`no`/`unrecognized`). The only failures are the two pre-existing
  `Test_scaffold` compile cases, reproduced identically on unmodified
  `origin/main` in this environment (the scaffold's `dune build` needs the
  framework opam pins), so they are not caused by this change.
- `internal/ci/check_production_infra.py`'s boundary-lease assertion is
  unchanged: the Role still grants exactly `get`/`create`/`update`/`delete`.

**Demo/example coverage:** Not applicable — release maintenance in the OCaml CLI;
no app-author surface.

**TypeScript-parity note (DEC-022):** No language-parity impact — release
retention is OCaml CLI lifecycle, not an application-facing contract.
