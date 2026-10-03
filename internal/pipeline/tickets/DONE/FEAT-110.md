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

## Completion notes (2026-10-03)

**The durable owner is the target cluster, and it is now stated as the design,
not left as an implementation detail.** Release and rollback metadata is held as
ordinary labelled Kubernetes ConfigMaps in the customer's own namespace —
`sol-release-<id>` (immutable), `sol-release-current-<workspace>` (the rollback
pointer), `sol-deployment-<id>` (one attempt) — and a GitOps `--emit-to` deploy
writes the same release record into the customer's own git repository. That keeps
a Sol-operated service and a second infrastructure-state database out of the
picture (ADR 0003), and it means the record outlives the use of Sol. The contract
is documented as `docs/architecture/devops-pipeline.md` § *Where release history
lives, and reading it without Sol*.

**Readable without Sol, demonstrated.** The same section (and the tutorial's
day-two operations, § *Both records live in your own cluster*) carries the
`kubectl` + `jq` recipe that walks from the label selector to the current pointer
to the release record: identity, each workload's applied image digest, and the
migrations applied with it — enough to describe what runs and to choose a
rollback target with no Sol binary in the loop. The recipe uses the labels the
records actually carry (`sol.dev/workspace`, `sol.dev/type`), not an assumed
namespace.

**Provenance is observed, and the observation is recorded (absorbs AUDIT-075).**
`Sol_cli_deployment_attempt` now resolves the actor through an explicit
precedence — a CI claim from the environment (`ci:github-actions`, `ci:gitlab`),
then the workspace repository's `git config user.email` (`git:local`), then
`SOL_ACTOR` (`override:env`), then nothing — and records the source beside the
name (`actor_source` in the record, shown as `ACTOR` in `sol deployments`). An
actor is never invented, and an unverified string can no longer read like a
signed identity. Tests pin the precedence order and the rendered source.

**Retention is stated (AUDIT-076 kept).** Committed release records are pruned to
the last `--keep-releases N` distinct releases (default 20, DEC-018) with the
current pointer and its predecessor always kept; deployment events are
deliberately **not** pruned, and that is now documented as the policy rather than
an oversight — an attempt history that silently loses its oldest entries is worse
than a large one, and the capacity question keeps AUDIT-076's own trigger
(measurable ConfigMap growth, or a cross-cluster history need). Its settlement
note is in `internal/pipeline/tickets/BACKLOG/AUDIT-076.md`.

**Absorb-or-keep, recorded:** `AUDIT-075` **absorbed** — implemented here and
moved to `DONE/` in this PR (promoted out of `BACKLOG/` first, since the state
machine has no `BACKLOG/` → `DONE/` move). `AUDIT-076` **kept** — its subject is
the pruning mechanism, which this ticket defines the policy for but does not
build.

**Stale-version reporting** was settled separately by AUDIT-077 (the record
carries the `encoding_version` that wrote it; a mismatch is a format change, not
corruption, and both paths fail closed), and the new section states that a reader
with no Sol binary can see the same marker.

**Demo/example coverage:** the tutorial's production section now carries the
runnable `kubectl` read of the release history and rollback target, so a reader
can reproduce the portability claim without the CLI. `examples/pluto` needs no
change: nothing in its workspace or generated manifests changed, and its local
flow never reads these records by hand.

**Checks:** `dune build cli/`, the cli inline suite (new: provenance precedence,
the `ACTOR` column with its source, the `actor_source` round trip), `dune fmt`,
`internal/ci/check_ocamlformat.sh --all`, and `internal/ci/run_fast_checks.sh`.

**Not verified here:** the recipes in the docs are written from the record
shapes the readers parse, not executed against a live target — this session has
no cluster credentials. A qualification run should exercise them once
(HARDEN-007's territory), and the AWS/GCP harness tickets own that step rather
than this one.

**TypeScript parity (DEC-022):** no impact — this is the CLI's own on-cluster
metadata; no framework primitive, schema-registry convention or runtime contract
changed.
