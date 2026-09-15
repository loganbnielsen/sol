---
id: FEAT-080
type: feature
severity: low
source: user observation 2026-09-15 (recent framework growth -- FEAT-077/078/079 --
  had no counterpart update against the TS dogfood spike's own recommendations);
  refreshed 2026-09-15 after review found the premise stale in both directions
  (the spike predates the shipped `@sol/*` packages; FEAT-077 had not merged)
---

**Depends on:** None.

**Related:** FEAT-033 (the 2026-09-07 TS dogfood spike this ticket updates
against), DEC-021, FEAT-076, FEAT-034, FEAT-035, FEAT-038, FEAT-039,
DOCS-010 (all `DONE`), and FEAT-077 (in flight on `FEAT-077/sol-jobs`,
PR #266, as of 2026-09-15).

Catch up `pipeline/dogfood/2026-09-07_typescript_demo_spike.md`'s
porting-surface analysis against what has actually landed on both sides of
the language boundary since it was written, so the gap is recorded rather
than silently rediscovered wholesale the next time someone asks "what would
a TS port need."

## Status — premise refreshed 2026-09-15

The ticket was written as if the TS-parity question were still open and
FEAT-077/078/079 the only things to reconcile. Both are now false:

- **The build decision this ticket deferred to has been made.** `@sol/kafka`
  (FEAT-034) and `@sol/obs` (FEAT-035) were deliberately unblocked on
  2026-09-08 for the `demo_ts` showcase — not on the organic-demand trigger
  the spike's recommendation named — then dogfooded (FEAT-038), CI-covered
  (FEAT-039) and documented (DOCS-010). `demo_ts` imports both packages
  today. The spike's "build, in this order, if/when…" recommendation has
  therefore already been executed; its capability table is a snapshot of a
  *hypothetical* layer that now has a real implementation to compare
  against.
- **FEAT-077 had not merged when this ticket was filed.** It is
  `READY_FOR_ENGINEERING`, in flight on `FEAT-077/sol-jobs` (PR #266); only
  FEAT-078/FEAT-079 are on `main`. Any reconciliation written against
  "FEAT-077 shipped" must wait for that merge or read the branch explicitly.

So this is **bookkeeping that is now overdue, not a speculative ticket**:
the inventory is stale relative to code that already exists. It is no
longer blocked — but "no longer blocked" is not "must be done next".
Prioritise it on its own merits, and do not read it as a build mandate for
`@sol/http`, a `@sol/jobs` equivalent, or anything else (see Principle).

## Principle — parity is capability-driven, not library-driven

The useful invariant is:

> Every new language-facing Sol capability must explicitly account for
> cross-language parity.

Parity does not mean cloning every OCaml module into npm. It means a
TypeScript author has access to the same **Sol platform capabilities**,
with language-idiomatic APIs where that is the right shape (`@sol/kafka`
wraps `kafkajs`; it does not reimplement `kafka-eio`). Each capability
resolves to exactly one recorded verdict:

- **implemented** in the TS layer,
- **already equivalent** via an ecosystem library (no Sol-specific
  convention to port),
- **intentionally deferred** (with the trigger that would revisit it), or
- **not applicable** (no app-author-facing surface — e.g. a pure
  Kubernetes-manifest field).

The failure mode this guards against is not "we forgot to port a module" —
it is a capability that silently has *no verdict at all*, so nobody can
tell whether TS parity is missing or merely unnecessary. Programming-model
concepts — Kafka stream consumption vs. `sol-jobs`' durable leased jobs
(DEC-021) — are the capabilities most likely to need an explicit verdict,
because they are what an app author actually programs against. The
inventory this ticket produces is what makes that verdict cheap to state
instead of re-deriving.

## Problem

The 2026-09-07 spike (FEAT-033) built `examples/pluto/app/demo_ts/` by
hand-porting `examples/local-demo`'s svc→Kafka→worker shape, found real
bugs doing it, and produced a capability table + build recommendation
(`@sol/kafka` bundling schema registry + topic provisioning + wire format
+ trace propagation + retry/crash semantics; `@sol/obs` for metric/log
conventions; `@sol/http`/`@sol/worker` as lower-priority sugar). That
table and recommendation are a snapshot of the framework *as it existed on
2026-09-07*.

The framework has since moved in two directions at once, and the spike
predates both.

**OCaml-side conventions the table is about, added after it was written:**

- **FEAT-078** — split `sol-worker` into `WORKER`/`RETRYABLE_WORKER`
  tiers, changed `retry_strategy` to a mandatory argument with no
  default, added `jitter_ratio` to the retry-policy vocabulary, and
  changed `Dead_letter` semantics under `In_memory`. The spike's own
  round-1/round-2 reviews already found the TS port's hand-rolled
  retry/crash handling wrong in two separate ways *before* this change —
  FEAT-078 moved the OCaml target further from what `demo_ts`'s worker did
  when the spike measured it.
- **FEAT-079** (+ BUG-031) — made `-fn` CPU/memory requests/limits and
  `scheduled_concurrency`/`backoff_limit` explicit `sol.toml` fields, and
  added `sol fn run` for manual invocation. `-fn` was explicitly out of
  scope for the 2026-09-07 spike ("judged to add little new information
  ... beyond what svc+worker already exercises") — that judgment predates
  `-fn` having any resource-configuration story at all.
- **FEAT-076 / DEC-021** — `sol-worker` handlers now return an explicit
  `Ack | Retry of string | Dead_letter of string` outcome, routed through
  retry/DLQ topics with group-scoped naming (`<source>.<group>.retry` /
  `.dlq`, `X-Sol-Origin-Group` provenance). The capability table has no
  row for this at all. `@sol/kafka`'s `wrapEachMessage` currently encodes
  the *older* decode-reject/retry/crash policy only — it exposes no
  `Ack`/`Retry`/`Dead_letter` outcome and no retry/DLQ-topic convention.
  This is a concrete, checkable gap, not a hypothetical one.
- **FEAT-077** — introduced `sol-jobs`, a new Postgres-backed durable
  leased-job library/concept that did not exist in any form on
  2026-09-07. This is not a refinement of something the table already
  covers (Kafka/schema-registry/tracing/retry); it is a second
  programming model (`sol-worker`/Kafka: "this happened" vs.
  `sol-jobs`/Postgres: "this must happen", DEC-021) with no entry in the
  table.

**TS-side work the table's own recommendation produced, which the ticket
did not previously account for:**

- **FEAT-034 / FEAT-035** — `@sol/kafka` and `@sol/obs` now exist in
  `packages/`, built from that capability table. Several of its
  "Likely/Maybe helper?" rows can now be judged against real shipped code
  instead of in the abstract.
- **FEAT-038** — `demo_ts` was migrated onto both packages; the
  hand-rolled `schemaRegistry.ts`/`tracing.ts`/`metrics.ts`/`loki.ts`/
  `wire.ts` files the spike measured were deleted. The spike's line-count
  table no longer describes the demo.
- **FEAT-039 / DOCS-010** — the demo has CI coverage and is documented.

## Non-goals

- Does not build `@sol/kafka`, `@sol/obs`, `@sol/http`, or a `@sol/jobs`
  equivalent — this ticket is inventory, not implementation.
- Does not re-run the `demo_ts` spike end-to-end, unless doing so turns
  out to be the cheapest way to produce an accurate updated capability
  table (judgment call for whoever picks this up).
- Does not change FEAT-076/077/078/079's own status or completion notes.
  (FEAT-078/079 are `DONE`; FEAT-077 is still in flight on PR #266 as of
  2026-09-15 — correct that premise when this is worked, don't re-file.)

## Remediation

When this is prioritised:

1. Re-read the spike's capability table and recommendation against what has
   actually shipped — FEAT-076/077/078/079's real `.mli`/`.md` spec docs
   (not just ticket summaries; the spike read OCaml source directly rather
   than inferring conventions), *and* the now-real `packages/sol-kafka` /
   `packages/sol-obs` surfaces. Rows judged "Likely/Maybe" against a
   hypothetical layer can now be marked resolved against real code.
2. Update or annotate the capability table per capability: does FEAT-078's
   mandatory `retry_strategy`/tiered `WORKER`/`RETRYABLE_WORKER` split
   change what `@sol/kafka` would need to expose? Does FEAT-079 change the
   "`-fn` was out of scope" judgment? Does FEAT-076's `Ack | Retry |
   Dead_letter` / retry-DLQ-topic convention belong on `@sol/kafka`'s
   surface (and if so, is its absence recorded as deferred with a trigger,
   or as a live gap)? Does `sol-jobs` belong as a new row (a `@sol/jobs`
   candidate, Postgres `FOR UPDATE SKIP LOCKED` leased-job library — note
   there is likely a suitable existing npm ecosystem package for this
   exact pattern, unlike the schema-registry/wire-format gap which had no
   ecosystem equivalent at all; that distinction matters for the
   "already equivalent vs. intentionally deferred" verdict, not just its
   prose).
3. Record which conventions genuinely widen the porting gap, and which
   don't (e.g., a pure Kubernetes-manifest change like FEAT-079's
   `scheduled_concurrency`/`backoff_limit` may be entirely CLI/deploy-side
   and not something a TS app author's own code needs to replicate at all —
   verify per-item, don't assume every framework ticket widens the gap).
4. Leave the build-or-don't recommendation and its gate exactly as strict
   as the original for any capability the table concludes should be
   *built* — this ticket's job is accuracy of the inventory, not advocacy
   for building sooner.
5. Give every capability an explicit verdict from the set in Principle —
   implemented / already equivalent / intentionally deferred / not
   applicable — including the programming-model rows the original table
   never had (FEAT-076 outcome contract, FEAT-077 `sol-jobs`, FEAT-078
   retry tiers, FEAT-079 `-fn` resources). A row with no verdict is the
   bug this ticket exists to prevent; "not applicable, because it is
   deploy-side" is a complete answer, silence is not.

## Acceptance criteria

- The capability table (or a clearly-dated addendum to it) reflects what
  has actually shipped — FEAT-076/077/078/079 on the OCaml side, and
  FEAT-034/035/038/039 on the TS side — not 2026-09-07's snapshot.
- Every capability row carries one explicit verdict from
  implemented / already equivalent / intentionally deferred / not
  applicable; no row is left silent.
- `sol-jobs` gets its own capability-table entry (or an explicit verdict
  on why it doesn't need one), and the `Ack | Retry | Dead_letter` /
  retry-and-DLQ-topic convention (FEAT-076, FEAT-078) is checked against
  `@sol/kafka`'s current surface — recording, at minimum, that
  `wrapEachMessage` does not expose that outcome today.
- The old "preserve the `Blocked On` gate" criterion is gone: the premise
  it protected (the build decision was still pending) no longer holds.
  This ticket records the inventory; it does not mandate building
  `@sol/http`, `@sol/jobs`, or any other package.

## Completion notes (2026-09-15)

Reconciliation landed as a dated addendum:
`pipeline/dogfood/2026-09-07_typescript_demo_spike.md` → "Addendum —
capability-driven parity reconciliation (2026-09-15, FEAT-080)".

- Every capability from the 2026-09-07 table, plus FEAT-076/077/078/079's
  new conventions, now carries exactly one verdict (implemented / already
  equivalent / intentionally deferred / not applicable). No row is silent.
- The spike's recommendation items 1 (`@sol/kafka`) and 2 (`@sol/obs`) are
  recorded as built (FEAT-034/035/038/039/DOCS-010); item 3 —
  `@sol/http`/`@sol/worker` — remains FEAT-036, intentionally deferred.
- `sol-jobs` gets its own row: **intentionally deferred** (a second
  programming model per DEC-021; the mechanism likely has an npm ecosystem
  equivalent, and only the metric/topology convention is Sol-specific).
- `-fn` `scheduled_concurrency`/`backoff_limit` + `sol fn run` get
  **not applicable** (deploy-side/CLI surface, language-neutral).
- The `Ack | Retry | Dead_letter` / retry-and-DLQ-topic convention was
  checked against `@sol/kafka`: confirmed as the one real gap.
  `wrapEachMessage` exposes neither the outcome nor the retry/DLQ topology,
  and inherits `kafkajs`'s implicit retry — the "implicit substrate
  behavior" FEAT-078 removed on the OCaml side. `@sol/obs`'s
  `WorkerMessageStatus` also predates FEAT-076/078 (missing `dead_letter`,
  `relay_published`, `relay_failed`). Follow-up filed as FEAT-081.

**Demo/example coverage:** exempt — pure documentation (a dated addendum to
an existing findings doc); nothing an app author runs or imports changes.

**TS-parity impact:** none — this ticket *is* the TS-parity inventory; it
changes no convention and introduces no framework concept.

