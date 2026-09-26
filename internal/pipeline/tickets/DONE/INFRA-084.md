---
id: INFRA-084
type: bug
severity: medium
title: The GCP harness fixes the qualification target key, so a second attempt inherits the first attempt's Terraform state
source: preparing the FND-0058 live qualification (INFRA-079 / HARDEN-006)
---

**Depends on:** None.

**Related:** `INFRA-082` (the preserved Attempt 8 stale platform state), FND-0058 / `INFRA-079`,
`internal/qualification/gcp/live-qual.sh`.

## Problem

`live-qual.sh` sets `TARGET="qual/gcp/us-central1"` as a constant, while `CLUSTER` is required to be
unique per run. The target names the Terraform state objects (`sol/<target>/<layer>.tfstate`), so the
constant defeats the per-run identity: **a second attempt starts from the first attempt's state.**

Observed consequence (Attempt 8, 2026-09-25): its failed install left the platform root of
`qual/gcp/us-central1` holding 11 resources whose objects no longer exist. Any later attempt reusing
that key would begin with that state as its own starting condition — so a qualification that means to
produce its own failed-install specimen would instead inherit someone else's, and would overwrite the
preserved evidence that `INFRA-082` owns.

## Remediation

Make the target key overridable, exactly as `CLUSTER` is: `TARGET="${TARGET:-qual/gcp/us-central1}"`,
with the reason stated at the definition (the key names state objects; a shared key is shared state).
The default keeps every existing runbook working.

## Acceptance criteria

- `TARGET=qual9/gcp/us-central1 live-qual.sh destroy` invokes `sol cloud destroy
  qual9/gcp/us-central1` and reads `sol/qual9/gcp/us-central1/…` state objects, and does **not**
  touch the default key's objects (test, both directions).
- The default is unchanged when the variable is unset.
- A qualification attempt can therefore produce a fresh specimen without inheriting, or disturbing,
  another attempt's state.

## Completion notes (2026-09-25)

Landed with the FND-0058 live qualification preparation; the run that follows uses
`TARGET=qual9/gcp/us-central1` and `CLUSTER=sol-qual-gcp-9`, so the preserved Attempt 8 state is
neither inherited nor overwritten. Demo/example: not applicable (qualification harness). Language
parity (DEC-022): no application-facing impact. The harness's own suite is 90 assertions, green.

## Live use (2026-09-26)

The FND-0058 qualification run used `TARGET=qual9/gcp/us-central1` and produced its own specimen; the
preserved Attempt 8 platform state (11 resources / serial 4) was neither inherited nor overwritten.
Record: `internal/qualification/records/2026-09-26-gcp-fnd0058-live-qualification.md`.
