---
id: HARDEN-006
type: verification
severity: high
title: GCP qualification attempt 8 — get past cert-manager's startupapicheck to platform Ready
source: docs/qualification/README.md (the run that replaces the HARDEN-004 epic's frontier)
---

**Depends on:** INFRA-076.

**Related:** HARDEN-004 (closed epic), FND-0010, FND-0007, DEC-042, DEC-043.

## Blocked On

Explicit operator authorization for a live, billable GCP run, and a fresh Phase-0 read-only
baseline of `sol-qualification`. Promote to `READY_FOR_ENGINEERING` only when both exist.

## Goal

Reach platform `Ready` on a disposable GCP target. Every GCP attempt so far stopped at or before
`helm_release.cert_manager`'s post-install `startupapicheck` Job (Attempt 4; FND-0010), with
cert-manager itself healthy. The first task is to establish *why* that check fails, from the check
container's own output, captured while the target is up. Disabling the check to make the release
pass is explicitly not the fix.

## Why it depends on INFRA-076

Until Terraform is supervised so that Sol's death cannot kill it with SIGPIPE, a live run can
reproduce the only known Sol-caused provider/state divergence. Do not spend on a live attempt
before that is fixed.

## Acceptance criteria

- Run under the operating rules in `docs/qualification/README.md` (cost rule; `Absent`; process
  identity, not patterns; no force-unlock of a live lock; no signals to provider plugins).
- `terraform state pull` captured into the evidence bundle before any teardown.
- A run record `docs/qualification/<date>-gcp-attempt8.md` from `run-record-template.md`, with the
  matrix rows qualified, blocked or not reached — each stated.
- Teardown to `Absent`, verified independently of Sol's report.
- `internal/pipeline/audits/QUALIFICATION_STATUS.md` updated.
