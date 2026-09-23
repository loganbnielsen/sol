---
id: INFRA-067
type: bug
severity: high
title: A target Sol accepts for creation must retain a destruction path
source: FND-0029 — GCP Attempt 5 (2026-09-22)
---

**Depends on:** None.
**Related:** `FND-0029` (the evidence), `FND-0007` (the refusal's wording and the
missing Cloud DNS solver), `FND-0028` / `DEC-043` (durable prerequisites and which
stage owns them), `docs/qualification/2026-09-22-gcp-attempt5.md`.

## The invariant to establish

> **Any target Sol permits to create billable infrastructure must retain a supported
> destruction path without requiring undocumented configuration surgery.**

## What happened

A GCP target declaring `cluster_issuer: letsencrypt-staging` was accepted by
`sol cloud apply --apply` (14 resources created) and refused by
`sol cloud destroy --apply` in the `PreparingDestroy` phase, with the
`cluster_issuer`/Cloud-DNS-solver refusal. `sol cloud destroy --plan` accepts the same
target, so the fault is in the mutating destruction path, not target parsing. The
teardown only proceeded after `cluster_issuer` was removed from the untracked target,
which is the correction the refusal's own text prescribes.

## Why this is high severity

The refusal is correct in intent — Sol should not pretend it can wire a certificate
issuer on GCP today — but it is evaluated at a moment where it has no remediation
available and where it blocks the one supported way to stop spending money. A safety
check that strands billable infrastructure is worse than the failure it guards
against, and here it required an operator who could read the error and know that
editing the declaration was safe.

## Remediation

The requirement is the invariant; the mechanism is deliberately not prescribed here,
because the evidence supports more than one repair:

- **Do not run install-time validation in `PreparingDestroy`,** or evaluate it in a
  form that a destruction-only phase can satisfy — the platform is not being installed
  during a destroy, so a guarantee about the platform's issuer is not actionable there.
- **Or refuse the configuration at creation.** If Sol cannot install what the
  declaration asks for, and that inability also makes the target unsafe to destroy,
  then the declaration should not be accepted in the first place. This is the weaker
  option only in the sense that it spends nothing but also builds nothing: it does not
  by itself restore a destruction path for targets already in that state.

Whichever is chosen, install-time validation must not be weakened, and a target that
has *already* been created in the refused shape must still be destroyable.

## Acceptance criteria

- `sol cloud destroy --apply` succeeds on a target that `sol cloud apply --apply`
  accepted, with no edit to the target declaration between the two commands.
- A regression test fails if the `PreparingDestroy` path can be refused by a
  validation that creation accepts. Prefer a test that does not require billable
  resources (the refusal is reachable before any resource is destroyed, so a state
  fixture or an offline harness is sufficient).
- The class is checked, not just the instance: any other install-only validation
  reachable from the destruction path is either made destroy-safe or explicitly
  recorded as out of scope.
- Install-time validation is demonstrated unchanged.

## Out of scope

- The Cloud DNS solver itself (`FND-0007`), which is what makes the refusal correct
  today. This ticket is about *when* the refusal is evaluated.
- Which stage owns durable prerequisites (`DEC-043`).
