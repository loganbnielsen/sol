---
id: INFRA-078
type: bug
severity: high
title: The qualification harness mis-reads the provider's NOT_FOUND, and `verify` can escalate to teardown
source: GCP Attempt 8, Phase 0 (2026-09-25) — the stopped pre-live execution
---

**Depends on:** None.

**Related:** HARDEN-006 (the run whose Phase 0 found these), `internal/qualification/gcp/live-qual.sh`,
`internal/qualification/records/2026-09-25-gcp-attempt8-phase0-stop.md`.

## What happened

Attempt 8's read-only Phase 0 (`live-qual.sh verify`) stopped the run before any mutation with four
classes at `UNKNOWN`. The evidence names two harness defects, both found by running the merged harness
against the real provider. Neither is a provider or a product defect.

### A. `provider_probe` does not recognise the provider's own not-found vocabulary

Captured verbatim in the stopped run's bundle
(`/tmp/sol-gcp-qual-8/inventory-service-account-provisioner.stderr`):

```
ERROR: (gcloud.iam.service-accounts.describe) NOT_FOUND: Unknown service account. This command is
authenticated as lbendtlynielsen@gmail.com which is the active account specified by the
[core/account] property
```

`provider_probe` classifies a failed read as ABSENT only when the output matches
`(not[ -]?found|does not exist|was not found|notFound|404|No URLs matched)`. `NOT_FOUND` carries an
**underscore**, which `[ -]?` does not cover, so a genuine not-found is reported `UNKNOWN`. Four
classes are affected: the three service-account describes and the service-account IAM policy.

The behaviour is **fail-closed** — never a false ABSENT — but it makes the continuation gate
unreachable, so every attempt would stop in Phase 0.

### B. `verify` escalates to a teardown when verification fails

`verify` sets `KEEP=1` **after** its failure branch exits, so the EXIT trap's "a failed run is
presumed to have created something" rule calls `destroy`. Recorded live: the stopped run's bundle
contains `destroy.log`, holding a `sol cloud destroy … --apply` invocation issued by a `verify` run.

It mutated nothing only because no target file existed — the CLI refused before touching the provider.
With a target file present it would tear down the target the operator asked merely to inspect,
contradicting the subcommand's documented contract (`verify does not mutate; nothing to tear down`).

## Remediation

- **A.** Recognise the provider's actual wording with the smallest correct change:
  `not[_. -]?found`. The case-insensitive match already covers the camel-case form, so the redundant
  `notFound` alternative goes. **Do not** broaden unclassified failures into ABSENT: permission
  denied, transport/API failures and malformed responses must stay `UNKNOWN`.
- **B.** Make the invariant structural rather than positional: establish the no-cleanup state
  **before** the verification call that can fail, so that no path out of `verify` — success, failure,
  or a signal on the way — can reach `destroy`.

## Acceptance criteria

- A regression test uses the **actual captured provider wording** (verbatim from the stopped run's
  stderr files), and establishes each direction: `NOT_FOUND: …` → ABSENT; a returned object →
  PRESENT; permission denied → UNKNOWN; transport/API failure → UNKNOWN; an unclassified or
  malformed response → UNKNOWN.
- The test suite's provider stubs speak the provider's real vocabulary, so a paraphrase cannot mask
  this class again.
- A regression test provides a target file, makes verification fail, observes a non-zero result, and
  proves **no destroy command was invoked** — testing the invariant, not the position of a flag.
- `live-qual.sh verify` is read-only whether verification succeeds or fails.
- No product code changes; the GCP lifecycle, FND-0010 and the authorized live scope are untouched.

## Completion notes (2026-09-25)

**Found by** GCP Attempt 8's read-only Phase 0 from `1aad2623`:
`internal/qualification/records/2026-09-25-gcp-attempt8-phase0-stop.md`. That execution mutated no provider and
created nothing, and the accepted live-infrastructure attempt was not consumed by it.

**A — `provider_probe`'s not-found vocabulary.** `not[ -]?found` did not cover the provider's actual
`NOT_FOUND:` (underscore form). The pattern is now `not[_. -]?found`; the captured forms are named in
the comment, and the redundant camel-case alternative is gone (`grep -i` already covers it). Nothing
else was broadened — permission, transport and malformed responses stay `UNKNOWN`, and the tests pin
that in the failing direction.

**B — `verify` is observational.** `KEEP=1` and its reason are set **before** the verification call,
so no path out of `verify` — success, failure, or a signal on the way — can reach `destroy`. The fix
is stated as the invariant rather than as the position of a flag.

**Evidence (offline, no cloud mutation).** `internal/qualification/gcp/test-live-qual.sh`:
**87 assertions (was 74)**, all green. The new ones use the provider's **captured** wording verbatim —
the underscore `NOT_FOUND`, the compute `was not found`, permission denied, a
`gcloud crashed (ConnectionError)` transport failure, an `INVALID_ARGUMENT` response, and a returned
object for PRESENT — and a `verify` case that pre-seeds a target file, makes verification fail,
observes a non-zero result and proves no `destroy` was invoked (the invariant, not the flag).
Mutation-checked, each failing the suite: reverting the pattern, treating every failure as ABSENT, and
setting `KEEP` after the check.

**Demo/example: not applicable** — qualification harness only. **Language parity (DEC-022): no
application-facing impact.**
