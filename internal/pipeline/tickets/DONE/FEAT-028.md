---
id: FEAT-028
type: feature
severity: medium
source: docs/planning/LIVE_DEV_DEPLOY_ROADMAP.md
---

`Sun_cli_config`: model per-index DynamoDB keys and `aws:`/`gcp:` provider-boxed target fields.

**Depends on:** FEAT-025.

## Problem

Two related parsing gaps in `cli/sun/lib/sun_cli_config.ml`, split out of
`FEAT-025` because both require new parsing structure, not just fail-loud
hardening of existing structure:

1. **DynamoDB per-index key attributes are silently dropped.**
   `test_config.ml`'s own fixture proves it:
   ```yaml
   sessions:
     type: dynamodb
     indexes:
       by_expires_at:
         partition_key: tenant_id   # indent 8 — `| 8, _, Some _ -> loop ()`, dropped
         sort_key: expires_at       # same
   ```
   `resource.indexes` is currently `string list` — just names. This
   contradicts `LIVE_DEV_DEPLOY_ROADMAP.md`'s "DynamoDB resources require
   declared keys and indexes; they are never inferred from code" — that
   applies to each index's own keys, not just the resource's top-level
   `partition_key`/`sort_key`.
2. **`aws:`/`gcp:` provider-boxed fields under `target:` have no parsing
   support at all**, silently dropped or misrouted depending on file
   ordering (the ordering half of this — `root` never reset by `target:`
   — is fixed in `FEAT-025` item 5; this ticket adds the actual boxed-field
   parsing on top of that fix). `LIVE_DEV_DEPLOY_ROADMAP.md`: "Provider-
   specific fields stay boxed under `aws:` or `gcp:`. Promote a field to
   generic Sun language only when it has stable meaning across providers."

## Remediation

1. Change `resource.indexes` from `string list` to a list of
   `{ index_name : string; partition_key : string option; sort_key :
   string option }`, parsing indent-8 key/value pairs under each index
   name into it instead of dropping them. Update `cmd_plan.ml:35-36`
   (currently the only reader of `.indexes`) to print the new shape.
2. Add parsing for one `aws:`/`gcp:` boxed sub-section under `target:`,
   storing provider-specific key/value pairs keyed by provider name
   (exact field set: whatever's needed to unblock `FEAT-026`'s Terraform
   variable resolution — coordinate scope with that ticket, don't
   over-build a schema no consumer needs yet).
3. Tests: `by_expires_at` round-trips its `partition_key`/`sort_key`; an
   `aws:` box under `target:` round-trips; a `gcp:` box under a target
   whose provider path segment is `aws` still parses (boxing is per
   declared key, not filtered by the target's own provider — that
   filtering, if wanted, is a future ticket).

## Acceptance criteria

- `test_config.ml`'s `by_expires_at` fixture asserts its
  `partition_key`/`sort_key` values, not just its name.
- A `target: \n aws: \n vpc_id: vpc-123` block round-trips into a resolved
  target's provider-boxed fields.

## Closed — implemented outside the ticket pipeline

Merged directly to `main` (PR #96 for FEAT-025 "Harden target file parser", PR #97 for FEAT-028 "Model target provider fields and index keys") by a parallel session before this ticket was picked up here. Verified post-merge against this ticket's acceptance criteria: `.mli` added with concrete records, `resource.size`, `index` type with `partition_key`/`sort_key`, `target.provider_fields`, quote-aware `strip_comment`, duplicate rejection (resources/services/sections/provider boxes/index names), fail-loud unknown keys, `parse_int`/`parse_bool` returning `Result`, `..`-traversal rejection in `target_of_path` — all present. Moved to DONE for bookkeeping accuracy rather than left in `READY_FOR_ENGINEERING` describing already-shipped work.
