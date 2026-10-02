---
id: CODE_LAYER-028
type: refactor
severity: medium
title: Move the provider-independent absence helpers into Sol_cli_absence
source: internal/pipeline/audits/2026-10-02_code_layer_audit.md
premise: "rg -q '^let lines' cli/lib/base/sol_cli_absence.ml"
---

Move the provider-independent absence helpers into Sol_cli_absence

**Depends on:** None.

## Problem

`cli/lib/cloud/sol_cli_aws_absence.ml` and
`cli/lib/cloud/sol_cli_gcp_absence.ml` are provider adapters over one neutral
model, `Sol_cli_absence`. Four of their helpers are provider-independent and
duplicated:

- `lines` is byte-identical (`sol_cli_aws_absence.ml:32-37`,
  `sol_cli_gcp_absence.ml:27-32`).
- `unresolved` is byte-identical (`sol_cli_aws_absence.ml:423-429`,
  `sol_cli_gcp_absence.ml:366-372`).
- The `Terraform state bucket` `External` observation inside
  `durable_observations` is word-for-word shared; only its `identity` string
  differs.
- `not_found` has the same shape but two phrase sets, and they have already
  drifted: GCP accepts `was not found` and AWS does not.

The drift is the dangerous part. `not_found` decides whether a provider answer
becomes `Absent` — a claim that the resource is gone, which destroy
verification relies on — or `Unobservable`, which is fail-closed. Two adapters
disagreeing about the wording is a correctness difference living in duplicated
code, not a style question.

## Remediation

1. Move `lines`, `unresolved`, and the shared state-bucket
   `External` observation into `Sol_cli_absence`, where the observation type
   already lives. Parameterise the state-bucket entry by its `identity` (AWS
   and GCP word it differently).
2. Factor the not-found scan as `Sol_cli_absence.not_found ~needles reason`, and
   keep each adapter's phrase list explicit at its call site so the difference
   is visible in one place rather than hidden in a copy. Do not silently widen
   either list: `Absent` is a safety claim, and widening AWS's set would make
   more provider errors read as absence.
3. If, on inspection, the two phrase sets are meant to be one, record that
   decision in the code as a single list; do not leave them accidentally
   different.

## Acceptance criteria

- `Sol_cli_absence.lines`, `Sol_cli_absence.unresolved`, and the durable
  state-bucket observation exist once; the provider adapters call them.
- `cli/lib/cloud/sol_cli_aws_absence.ml` and `sol_cli_gcp_absence.ml` contain no
  byte-identical function bodies (the `lines`/`unresolved` copies are gone).
- `Absent`/`Unobservable` classification for each provider is unchanged for a
  representative failure message from that provider; the phrase sets are
  visible and, if different, deliberately so.
- `cli/test/inline/test_aws_absence.ml` and `test_gcp_absence.ml` still pass;
  add a case pinning the not-found classification for each provider.
- Update a runnable example/demo for application-facing behavior, or record why
  this is an internal-only refactor.
- Record the per-language capability verdict for framework/application
  contracts, or explain why language parity is unaffected.
