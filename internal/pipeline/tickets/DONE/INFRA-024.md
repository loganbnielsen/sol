---
id: INFRA-024
type: feature
severity: medium
title: Offline publisher/deployer identity boundary evidence
source: Maturity-A reconciliation, ADR 0002 publisher-identity item
---

**Depends on:** None.

**Related:** ADR 0002 (identity table), INFRA-022, HARDEN-002.

ADR 0002's identity table declares provisioner/publisher/deployer/operator
and the negative boundaries between them (publishing must not grant
deployment; deploying an existing digest must not grant publish/replace;
provisioner must not subsume publisher/deployer). INFRA-022 established and
qualified the provisioner's Kubernetes RBAC boundary; nothing verified the
publisher/deployer half, and nothing guarded against a future change
silently blurring it.

## What was checked (static/offline evidence only — this is not the live
behavioral identity qualification ADR 0002 defers to HARDEN run 3)

Read every call site of `Sol_cli_docker`'s mutating operations (`build`,
`push`) versus its read-only ones (`manifest_exists`, `inspect_digest`):

- `cmd_cloud.ml`/`cmd_cloud_tf.ml` (the provisioner surface — `sol cloud
  plan/apply/destroy`) call neither `build` nor `push`, nor any other
  `Sol_cli_docker` function. The provisioner cannot publish today.
- `cmd_deploy.ml` (the deployer surface — `sol deploy`, the production path
  that consumes an already-resolved digest) calls only `manifest_exists`
  (existence/digest check before applying); it never calls `build` or
  `push`. Deploying an existing digest cannot also replace it today.
- `cmd_up.ml`/`cmd_migrate.ml` do call `build`/`push` — this is expected and
  out of scope: `sol up` is the local/dev inner-loop command (DEC-016's
  "Sol builds it" path, one operator, no separate trust domain to protect),
  and `sol migrate apply` builds and runs its own throwaway migration-runner
  image, a different capability than deploying an application artifact. ADR
  0002's identity table is scoped to the production cloud-target lifecycle,
  not these.

For a single CLI binary with no separate runtime privilege boundary, this
call graph *is* the effective permission: a capability that is never invoked
from a code path cannot be exercised from it. That is why a grep-based guard
here is real evidence, not the policy-text grep this pass was asked to avoid
(the caution applies to scanning IAM/policy JSON, which can misrepresent what
is actually reachable — a direct call-site check for a function's only
possible call sites does not have that gap).

## What changed

Turned the one-time check above into a permanent guard so a future change
can't silently reintroduce either capability:

- `internal/ci/check_publisher_deployer_boundary.sh` — fails if
  `cmd_cloud.ml`/`cmd_cloud_tf.ml` or `cmd_deploy.ml` reference
  `Sol_cli_docker.build`/`push`.
- `internal/ci/test_publisher_deployer_boundary.sh` — mutation test: confirms
  today's repo passes, then confirms the guard rejects an injected `push`
  call in `cmd_deploy.ml` and an injected `build` call in `cmd_cloud_tf.ml`.
- Wired into `.github/workflows/ci.yml` alongside the other `internal/ci`
  guardrails (same job, same pattern as the public-cloud-lifecycle guard).

## Not in scope

- Live AWS/IAM identity qualification (whether the credentials actually used
  at runtime are scoped this way) — HARDEN run 3.
- `sol up`/`sol migrate`'s own build+push+run capability — not a boundary
  violation of ADR 0002's cloud-target identity table, which doesn't cover
  local dev or the migration-runner's throwaway artifact.

**Demo/example coverage:** not applicable — CI guardrail only, no
app-author-facing surface changed.

**TypeScript parity:** not applicable — the guard is over the OCaml CLI's own
call graph, not a per-language application capability.
