---
id: INFRA-114
type: infra
severity: low
source: validation workflow review 2026-10-05
title: Run the TypeScript Kubernetes smoke only for changes that can affect it
---

**Depends on:** INFRA-113, INFRA-115.

## Premise verified

`.github/workflows/ci.yml` runs `golden-path-smoke-ts` for every change classified as neither
`docs-only` nor `ocaml`. That includes `internal/ci/` hook and test changes. The job is explicitly
not a required check, but still provisions k3d and deploys the TypeScript demo. On INFRA-109 PR
#1079's first run, it spent 18m12s and failed at 624s with `order_svc rollout failed` because
`configmap "order-svc-env" not found`; the hook change did not touch the TypeScript demo.

The required `test` check currently runs a broad suite for nearly every non-docs PR. INFRA-115
replaces that membership with independent per-PR checks selected by affected surface, while retaining
a broad full-suite run on `main` and for unknown or global PR impact. This smoke is additional,
environment-sensitive evidence about the TypeScript deployment path, not a prerequisite for every
tooling or qualification change.

## Remediation

Use an explicit product-impact classification to run this smoke when a change can affect the
TypeScript application contract: TypeScript framework/demo sources, shared CLI or scaffold behavior,
or shared deployment/platform assets used by the demo. Skip it for isolated hook, CI-test,
qualification-harness and maintainer-tooling changes. Use INFRA-115’s shared impact plan. Treat unknown or mixed product paths conservatively and keep
classifier failure fail-closed. Preserve full main-branch broad validation, including this smoke in
the broad lane if its deployment environment remains available; select it on PRs when the affected
surface can influence the TypeScript golden path. Emit a clear skip reason. Keep the smoke
non-required.

## Acceptance criteria

- The TypeScript golden-path smoke runs for TypeScript sources and shared CLI/scaffold/deployment
  changes that can affect the demo.
- Isolated `internal/ci/`, `internal/tooling/`, qualification-harness and ticket-only changes skip
  this Kubernetes smoke with an explicit reason.
- Shared or unknown product paths run the smoke; classifier errors never silently skip it.
- Tests cover TypeScript-only, shared CLI/platform, tooling-only, mixed and unknown paths.
- The job remains non-required and reports whether it ran or why it was skipped. Main-branch broad
  validation still exercises the TypeScript path independently; PR selection follows INFRA-115.
- Example impact: none; developer tooling. Language-parity impact: none.
