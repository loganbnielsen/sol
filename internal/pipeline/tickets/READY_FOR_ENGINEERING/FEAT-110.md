---
id: FEAT-110
type: feature
severity: medium
title: Make release history and rollback metadata portable and customer-owned
source: DEC-057 and docs/DEVELOPER_EXPERIENCE.md §2, §9 (2026-09-29)
---

**Depends on:** None.

**Related:** `DEC-057` §2/§9 (ownership and portability guarantees),
`DEC-018` (release identity sufficient for rollback), `DEC-019` (a hosted service
must not be required), `FEAT-090` (target status: cloud health, drift, last
operation), `AUDIT-075` (an unverifiable deployment-event actor), `AUDIT-076`
(no retention/pruning for deployment-event history), `AUDIT-077` (release-record
validation misreports a stale encoding version), `DEC-050` (where Terraform works
and what is retained there).

## What this is

`DEC-057` §9 requires that an operator who stops using Sol can still describe,
inspect and continue operating what was built. Release history and rollback
metadata are the part of that promise Sol does not yet make portable: `sol
releases`/`sol rollback` and the deployment-event record are Sol-shaped, and it is
not stated where the durable copy lives or that it survives the tool.

This is a product requirement, not a bug: the brief records "release history /
rollback metadata → durable customer-owned state where practical" as something
OSS Sol should deliver into the user's infrastructure rather than reserve for a
hosted tier.

## Required behaviour

- **Name the authority.** State where the durable release/rollback record lives,
  why that is the right owner, and what a user can read without Sol.
- **Survive the tool.** The record is durable and inspectable after Sol is
  uninstalled or a machine is replaced; the operator can reconstruct what is
  deployed and what a rollback would restore.
- **Be honest about what is recorded.** The record's actor, timestamp and
  provenance are verifiable facts, not arbitrary environment values
  (`AUDIT-075`); its retention and pruning behaviour is defined (`AUDIT-076`); and
  a stale schema version is reported as such rather than as corruption
  (`AUDIT-077`).
- **Stay within the target, not the tool.** Where practical, the durable copy is a
  standard resource in the customer's account rather than hidden Sol-side state.
- **Not be a hosted dependency.** The OSS path must work with no Sol-operated
  service.

## Remediation

- Decide the durable owner of the release record (target-owned standard resource,
  exported artifact, or an explicitly named local store) with `DEC-052`'s
  discipline: do not assert a fact that can be observed, and do not invent a
  second infrastructure-state database (ADR 0003).
- Reconcile with the three open audits instead of duplicating them: they are about
  the correctness of the record, this ticket is about its ownership and
  portability. Close or absorb them only if the implementation genuinely makes
  them moot; otherwise file this as the portability unit and leave them as the
  correctness units.
- Document how an operator reads the record without Sol and what a rollback does
  when Sol is gone.

## Non-goals

- Not a hosted release dashboard (`DEC-019`).
- Not a second infrastructure-state store or a phase-pointer file (ADR 0003).
- Not re-implementing `sol releases`/`sol rollback`; this is about where their
  durable data lives and what survives the tool.
- Not metering or billing history.

## Acceptance criteria

- The durable owner of release/rollback metadata is decided and documented.
- The record is readable and sufficient to identify the deployed release and a
  rollback target, without a Sol binary in the loop.
- Provenance (actor, time) is a verified fact, not an arbitrary environment value.
- Retention/pruning and stale-version reporting are defined.
- The OSS path requires no Sol-operated service.

**Demo/example coverage:** the portability claim is only credible if shown, so
`examples/pluto` (or the tutorial) must demonstrate reading the record and
identifying a rollback target without the CLI, and DOCS-029 must document it.

**TypeScript parity:** No language-parity impact — release metadata is
app-language neutral.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: DEC-057 §9 portability promise is open; `sol_cli_release` metadata is Sol-shaped with no stated durable owner (see AUDIT-075/076/077).

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).


## Required settlement (2026-10-03)

This ticket must settle the fate of `AUDIT-075` (deployment-event actor
provenance) and `AUDIT-076` (deployment-event retention/pruning): decide whether
their subject is absorbed into this ticket's durable, portable release/rollback
record, or remains independently necessary. Record absorb-or-keep in the
completion notes and close or keep the audits accordingly; do not leave the
question open.
