---
id: VERIF-028
type: verification
severity: medium
title: "Local integrated-qualification harness and run procedure (VERIF-027 prerequisite)"
source: internal/qualification/ALPHA_CAMPAIGN.md — VERIF-027 needs a run procedure, evidence capture and a tri-state teardown check
---

**Depends on:** None.

**Related:** VERIF-027, FEAT-131, FEAT-132, FEAT-133, RELEASE-006, BUG-130,
`internal/qualification/README.md`.

`VERIF-027` observes the alpha acceptance matrix's local rows against the reference
application on a fresh k3d cluster. This ticket lands the harness, the run procedure
and the offline tests that make that run executable the moment `RELEASE-006`,
`FEAT-132` and `FEAT-133` land — so the run is evidence collection, not instrument
building.

## Scope

- `internal/qualification/local/local-qual.sh`: phases `preflight`, `infra`,
  `status`, `rows`, `capture`, `teardown`, using a run-private kubeconfig
  (`k3d kubeconfig get sol-local`) and a tri-state (`ABSENT` / `PRESENT` / `UNKNOWN`)
  teardown verdict that refuses to report success unless absence is established.
- `internal/qualification/local/local-run-procedure.md`: the procedure, the
  environment prerequisites observed on 2026-10-03 (one `sol-local` cluster so local
  runs serialize; the host ports the run owns; kubeconfig isolation), the
  evidence-bundle layout, and the row-driver contract (`ROWS_SH`).
- `internal/qualification/local/test-local-qual.sh`: offline stubs and
  mutation-controlled assertions, including that a failed `k3d cluster list` is
  `UNKNOWN` and never `ABSENT`.

## Non-goals

- Not the run itself (`VERIF-027`) and not the row drivers, which need the reference
  applications.
- No product code. The product defect the preparation exposed — `sol local infra`
  answering Kubernetes operations from the ambient kubeconfig — is `BUG-130`, fixed
  separately.

## Acceptance criteria

- `bash internal/qualification/local/test-local-qual.sh` passes.
- The suite fails when the tri-state verdict is mutated to read a failed cluster
  query as `ABSENT` (mutation-checked).
- The procedure states the observed prerequisites and the deviations from the cloud
  run rules (no forced teardown; local absence is not a provider inventory).
- Demo/example: not applicable — qualification tooling, with no app-author-facing
  surface.
- Language parity: not applicable — no application-facing contract change.
