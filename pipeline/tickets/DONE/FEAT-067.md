---
id: FEAT-067
type: feature
severity: medium
source: split from FEAT-066, 2026-09-12 — slice 1 of the release record
---

**Depends on:** None.

**Premise checked 2026-09-12:** before this work, `rg 'Sol_cli_release|sol releases' cli/sol` matched nothing — no release record existed, and `sol_cli_deployment_state` wrote only the consumer-group state.

**Related:** DEC-018 (the decision this implements), FEAT-050 (digest-pinned artifacts — until it lands, resolved workloads carry image references, not digests), FEAT-065 (requested scope + resolved set in the plan), FEAT-066 (slices 2–3: rollback execution, leases and retention).

Write the release record on every deploy, and add `sol releases` to list them.

## Context

This is slice 1 of FEAT-066, split out so it can land read-only and with no
mutation risk, exercising the record shape against real deploys before rollback
depends on it. The mutation half — `sol rollback <release-id>`, the migration
boundary check, the lease and retention — stays in FEAT-066.

## Work

- **Record on deploy:** one immutable ConfigMap per release (`immutable: true`),
  written in the same `default`-namespace convention the existing
  `sol-deploy-state-<workspace>` ConfigMap uses. Labels for lookup
  (`sol.dev/type=release`, `sol.dev/target`, `sol.dev/scope`,
  `sol.dev/workspace`), annotations for the long fields.
- **Pointer object:** a mutable `sol-release-current-<workspace>` ConfigMap
  naming the current release, so `sol releases` and a later rollback can find
  "what is deployed" without scanning.
- Never store secret values — references (key names) only.
- **`sol releases`** lists id, commit, scope, created, newest first.
- Fields follow DEC-018: release id, created-at, workspace, target, git commit
  and dirty flag, requested scope, resolved workloads (name + image reference),
  migrations, mode. Artifact digests arrive with FEAT-050; until then the image
  reference is what the record can honestly carry.

## Acceptance criteria

- Every `sol up` and `sol deploy` writes a release record; `sol releases` shows
  it.
- A release ConfigMap cannot be edited in place (`immutable: true`).
- The record carries the requested scope and the resolved workloads, so a later
  rollback can restore the resolved set rather than today's membership of that
  scope.
- No secret value is stored — only names/references.

## Completion notes

Landed 2026-09-12.

- **`Sol_cli_release`** (pure): the record type and the DEC-018 fields, release-id
  and RFC3339 generation, label sanitization, JSON round-trip, and the two
  Kubernetes objects as JSON (kubectl accepts JSON as YAML).
- **Two objects per release**, both in the `default` namespace, following the
  existing `sol-deploy-state-<workspace>` convention: the immutable
  `sol-release-<id>` ConfigMap carrying `immutable: true`, labels
  (`sol.dev/type`, `sol.dev/workspace`, `sol.dev/target`, `sol.dev/scope`,
  `sol.dev/git-commit`) and the full record under `data.record`; and the mutable
  `sol-release-current-<workspace>` pointer naming the current release.
- **`Sol_cli_release_store`** applies both through `Sol_cli_kubectl.apply`, and
  lists through `kubectl get -l sol.dev/type=release,sol.dev/workspace=… -o json`.
- **`sol up` and `sol deploy`** record after a successful apply. A failure to
  record is a warning, not a fatal error — the deploy happened, and a missing
  record must be visible rather than pretended away.
- **`sol releases`** lists id, commit, requested scope, created and target,
  newest first.

Decisions worth recording:

- **Label values are sanitized, the body is exact.** Kubernetes label values
  cannot contain `/`, so `sol.dev/scope` stores `payments-charge_svc` while
  `data.record` and `data.requested_scope` keep the real text. Lookup is by
  label; truth is in the body.
- **Keys, not values.** The record stores config and secret *key names* plus the
  git commit and image references. Configuration values are recoverable from the
  commit, so nothing sensitive ever reaches a cluster-readable object.
- **`default` namespace**, matching `sol_cli_deployment_state`. Destination
  binding is FEAT-063; until then the record follows the ambient context, and
  `sol releases` reads the same one.
- **Digests are not there yet** because images are tag-pinned until FEAT-050;
  the reference is what the record can honestly carry today.

Verified:

- `dune build`, `dune fmt --preview` clean, full `cli/sol/test` suite passes
  (new `test_release`: 9 cases covering id/timestamp/labels, JSON round-trip,
  the ConfigMap object, the pointer, tolerant listing, table order, and
  `of_plan`).
- The immutability mechanism was checked against the local k3d cluster: a second
  `kubectl apply` reports `unchanged`, an in-place `patch` is rejected
  (`Forbidden: field is immutable when 'immutable' is set`) with exit code 1.
- The `golden-path-smoke` job now asserts, after its real `sol up`, that
  `sol releases` lists a release, that the current-release pointer exists, and
  that an in-place edit of the release ConfigMap is rejected.

Not in this ticket: `sol rollback` execution, the migration boundary check, the
lease and retention (FEAT-066).

Demo/example coverage: `sol releases` is a new CLI surface, so the runnable
command reference in `docs/guides/TUTORIAL.md` was updated (cheat-sheet row plus
a Day-2 prose paragraph).
