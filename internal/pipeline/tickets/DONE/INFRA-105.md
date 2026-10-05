---
id: INFRA-105
type: infra
severity: low
source: alpha.7 GCP qualification attempts, 2026-10-04
title: Require the FND-0010 classification artifact only when classification runs
---

**Depends on:** None.

## Premise verified

Re-verified 2026-10-04. `verify_bundle()` in `internal/qualification/gcp/live-qual.sh`
added `fnd0010-classification.txt` to the required members whenever `INSTALL_STATE=failed`,
but `capture_fnd0010()` returns early — and writes nothing — when the cluster is not
describable, so an install that failed before the platform stage (for example a cloud
bootstrap that failed before any cluster existed) left the bundle marked `INCOMPLETE` over
an artifact the run could never have produced. The failure-capture path does produce the
classification when it reaches `classify_fnd0010`.

## Remediation

`FND0010_STATE` records whether the discriminator was reached. The early-return paths write
an explicit `fnd0010-not-reached.txt` naming why (the cluster is not describable, or the run
credential addresses a replaced cluster), and `verify_bundle()` requires the reached
`fnd0010-classification.txt` only when `FND0010_STATE=reached`, and the not-reached marker
otherwise. A reached classifier whose artifact is missing remains a missing required member,
so an evidence failure in a phase the run did reach still fails the bundle. The manifest
prints the discriminator state. `FND0010_CLASSIFY=0` disables the classifier as a diagnostic
control, and a reached-but-disabled classifier is exactly the missing-artifact failure.

## Acceptance criteria

- A pre-provisioning validation failure yields a complete, correctly failed evidence bundle.
- A reached classifier without its artifact remains an evidence failure.
- Example impact: none; qualification machinery only. Language-parity impact: none.

## Checks

- `internal/qualification/gcp/test-live-qual.sh` — 298 passed, including: the bootstrap
  failure is a complete bundle whose manifest says `NOT REACHED` and whose
  `fnd0010-not-reached.txt` carries the reason; and a reached classifier with
  `FND0010_CLASSIFY=0` is an incomplete bundle naming `fnd0010-classification.txt`.

## Completion notes

An early legitimate failure no longer manufactures a downstream evidence failure. A
classifier the run did reach is still required to have produced its artifact. Example
impact: none; qualification machinery only, no demo or reference-application change.
Language-parity impact: none.
