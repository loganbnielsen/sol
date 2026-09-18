---
id: INFRA-023
type: bug
severity: high
title: RDS destroy preparation — finding 9b
source: HARDEN-002 run 2 finding 9b; ADR 0002
---

**Depends on:** None. Finding 9a (the `rds_deletion_protection` /
`rds_skip_final_snapshot` / `rds_final_snapshot_identifier` variables and
their production-safe defaults) already landed; this is the remaining half.

**Related:** ADR 0002, INFRA-022, HARDEN-002.

`sol cloud destroy`'s `prepare_destroy`/`verify_destroy_preparation` were
declared no-ops (`cli/sol/bin/cmd_cloud_tf.ml`, comment: "RDS remains Finding
9b"). Per ADR 0002's inverse-reconciliation section: disabling RDS deletion
protection must happen through a real applied state transition (a `-var` on
`terraform destroy` is inert against a resource's prior state), and the final
snapshot identity must be unique per destroy attempt rather than a constant
cluster-derived name.

**Premise verified** 2026-09-18: at branch start, `prepare_destroy`/
`verify_destroy_preparation` in `cli/sol/bin/cmd_cloud_tf.ml` were still the
no-op stubs with the "RDS remains Finding 9b" comment; confirmed by reading
the file before making any change.

## What changed

- `prepare_destroy` now runs a **targeted `terraform apply`**
  (`-target=aws_db_instance.postgres`) against the cloud root, overriding
  `rds_deletion_protection=false`, `rds_skip_final_snapshot=false`, and a
  freshly-minted `rds_final_snapshot_identifier=<cluster>-postgres-final-<ms
  epoch>` — a real ModifyDBInstance, not a destroy-time `-var`. Skipped
  entirely when the cloud substrate doesn't exist yet (nothing to prepare) or
  when the target never created an RDS instance (`aws_db_instance` absent
  from state).
- `verify_destroy_preparation` re-reads this root's own applied state via a
  new `Sol_cli_terraform.show_json` (`terraform show -json`) and asserts
  `deletion_protection = false` and `final_snapshot_identifier` matches the
  identifier just minted, before destroy proceeds. This is a self-check
  against the same root's state, deliberately *not* routed through
  `Sol_cli_cloud_lifecycle`'s typed output contract — that contract exists
  for cross-root wiring (AWS root → base root), not a root checking its own
  resource against itself.
- Removed the stale "KNOWN GAP, deliberately not patched here" comment block
  now that it's patched.

## Invariants preserved

- **Terraform state remains authority for managed existence.** No Sol phase
  pointer was introduced; preparation state is read back from
  `terraform show -json`, the same source of truth `aws_outputs` already
  uses for the cross-root contract.
- **Protection recovery.** A subsequent `sol cloud apply` already forces
  profile-derived values last in its own var precedence (see the comment at
  `cloud_init`'s `vars` computation), so `rds_deletion_protection=true` from
  the target's profile always wins on the next apply regardless of what
  `prepare_destroy` set — no new code needed for "apply reconciles back to
  protected Ready."
- **Rerunnable.** The targeted apply and its verification are idempotent; a
  destroy retried after failing later in the lifecycle re-runs preparation
  harmlessly (already-disabled protection, same or freshly re-minted
  snapshot id — both are safe to reapply).
- **Uniqueness.** Millisecond-epoch suffix, not the `.0f`-second resolution
  that risked a same-second collision on a fast retry.

## Offline evidence

`internal/ci/test_cloud_lifecycle_offline.sh` gained: an established-target
destroy asserting the targeted apply carries the override vars and runs
before the actual `terraform destroy`; a second destroy attempt asserting a
different snapshot identifier than the first; and an absent-target destroy
asserting no RDS-targeted apply is attempted. Required extending the shared
mock `terraform`/`aws`/`kubectl` scripts with a `DESTROYING=1` mode (apply
verifies presence, destroy verifies absence — the same three mocks serve
both, toggled by env var rather than duplicated) and a `terraform show -json`
mock backed by a marker file so `verify_destroy_preparation` sees the
targeted apply's effect. `cli/sol/test/test_tool_adapters.ml` gained an argv
shape test for the new `show_json` adapter function, matching its sibling
`output_json`/`apply`/`destroy` tests.

## Not in scope

- Live AWS qualification of the ModifyDBInstance/DeleteDBInstance calls
  themselves — HARDEN run 3, not this ticket (static/mechanism evidence only,
  per this pass's instructions not to promote offline evidence into a live
  qualification claim).
- GCP — `sol cloud destroy` already fails closed for non-AWS providers
  upstream of this code path.

**Demo/example coverage:** not applicable — this changes `sol cloud`'s
destroy-lifecycle internals, not a primitive, CLI surface, or generated
manifest an app author writes against.

**TypeScript parity:** not applicable — target provisioning is
language-neutral (DEC-022); no per-language capability is introduced.
