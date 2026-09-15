---
id: FEAT-080
type: feature
severity: low
source: user observation 2026-09-15 (recent OCaml framework growth --
  FEAT-077/078/079 -- has no counterpart update against the TS dogfood
  spike's own recommendations)
---

**Depends on:** None.

**Related:** FEAT-033 (the 2026-09-07 TS dogfood spike this ticket updates
against), DEC-021, FEAT-077, FEAT-078, FEAT-079.

Catch up `pipeline/dogfood/2026-09-07_typescript_demo_spike.md`'s
porting-surface analysis against what has actually landed on the OCaml
side since it was written — record the gap now so it isn't silently
rediscovered wholesale the next time someone asks "what would a TS port
need."

## Blocked On

Real TS demand, exactly as the original spike's own recommendation
gated `@sol/kafka`/`@sol/obs`/`@sol/http` ("build, in this order, if/when
a real TS user justifies it"). This ticket does not change that gate —
it only keeps the *inventory* the gate will eventually be evaluated
against current, so that whenever the gate does open, whoever picks this
up isn't starting from a week-plus-stale spike. Do not promote to
`READY_FOR_ENGINEERING` on this ticket alone; promotion still requires the
same real-workload trigger the original recommendation named.

## Problem

The 2026-09-07 spike (FEAT-033) built `examples/pluto/app/demo_ts/` by
hand-porting `examples/local-demo`'s svc→Kafka→worker shape, found real
bugs doing it, and produced a capability table + build recommendation
(`@sol/kafka` bundling schema registry + topic provisioning + wire format
+ trace propagation + retry/crash semantics; `@sol/obs` for metric/log
conventions; `@sol/http`/`@sol/worker` as lower-priority sugar). That
table and recommendation are a snapshot of the OCaml framework *as it
existed on 2026-09-07*.

Since then, three tickets changed exactly the kind of convention the
spike's capability table is about, with zero corresponding update to
that table or the `demo_ts` port:

- **FEAT-078** — split `sol-worker` into `WORKER`/`RETRYABLE_WORKER`
  tiers, changed `retry_strategy` to a mandatory argument with no
  default, added `jitter_ratio` to the retry-policy vocabulary, and
  changed `Dead_letter` semantics under `In_memory`. The spike's own
  round-1/round-2 reviews already found the TS port's hand-rolled
  retry/crash handling wrong in two separate ways *before* this change —
  FEAT-078 moved the OCaml target further, not closer, to what
  `demo_ts`'s worker currently does.
- **FEAT-079** (+ BUG-031) — made `-fn` CPU/memory requests/limits and
  `scheduled_concurrency`/`backoff_limit` explicit `sol.toml` fields, and
  added `sol fn run` for manual invocation. `-fn` was explicitly out of
  scope for the 2026-09-07 spike ("judged to add little new information
  ... beyond what svc+worker already exercises") — that judgment predates
  `-fn` having any resource-configuration story at all, and may no longer
  hold now that `-fn` has real, documented semantics worth porting or
  explicitly declining to port.
- **FEAT-077** — introduced `sol-jobs`, a new Postgres-backed durable
  leased-job library/concept that did not exist in any form on
  2026-09-07. This is not a refinement of something the spike's
  capability table already covers (Kafka/schema-registry/tracing/retry);
  it is a fourth concern (`sol-worker`/Kafka: "this happened" vs.
  `sol-jobs`/Postgres: "this must happen", DEC-021) with no entry in the
  table at all.

## Non-goals

- Does not build `@sol/kafka`, `@sol/obs`, `@sol/http`, or a `@sol/jobs`
  equivalent — this ticket is inventory, not implementation.
- Does not re-run the `demo_ts` spike end-to-end, unless doing so turns
  out to be the cheapest way to produce an accurate updated capability
  table (judgment call for whoever picks this up).
- Does not change FEAT-077/078/079's own already-`DONE` status or
  completion notes.

## Remediation

When this is eventually picked up (on real TS demand, per the gate
above):

1. Re-read `pipeline/dogfood/2026-09-07_typescript_demo_spike.md`'s
   capability table and recommendation section against FEAT-077/078/079's
   actual shipped behavior (not just their ticket summaries — the real
   `.mli`/`.md` spec docs, same discipline the spike itself used: it read
   OCaml source directly rather than inferring conventions).
2. Update or annotate the capability table: does FEAT-078's mandatory
   `retry_strategy`/tiered `WORKER`/`RETRYABLE_WORKER` split change what
   `@sol/kafka` would need to expose? Does FEAT-079 change the "`-fn` was
   out of scope" judgment? Does `sol-jobs` belong as a new row (a
   `@sol/jobs` candidate, Postgres `FOR UPDATE SKIP LOCKED` leased-job
   library — note there's likely a suitable existing npm ecosystem
   package for this exact pattern, unlike the schema-registry/wire-format
   gap which had no ecosystem equivalent at all; that distinction matters
   for the "Candidate helper?" column's reasoning, not just its verdict)?
3. Record whichever of FEAT-078/079/077's conventions genuinely widen the
   porting gap, and whichever don't (e.g., a pure Kubernetes-manifest
   change like FEAT-079's `scheduled_concurrency`/`backoff_limit` may be
   entirely CLI/deploy-side and not something a TS app author's own code
   needs to replicate at all — verify per-item, don't assume every OCaml
   framework ticket widens the gap).
4. Leave the build-or-don't recommendation and its gate exactly as
   strict as the original — this ticket's job is accuracy of the
   inventory, not advocacy for building sooner.

## Acceptance criteria

- The capability table (or a clearly-dated addendum to it) reflects
  FEAT-077/078/079's actual current behavior, not 2026-09-07's snapshot.
- Each of FEAT-077/078/079 gets an explicit verdict: widens the TS
  porting gap (and how) or doesn't (and why not) — not a blanket
  assumption either way.
- `sol-jobs` gets its own capability-table entry (or an explicit note on
  why it doesn't need one, if the eventual analysis concludes an existing
  npm job-queue library already closes that gap without any Sol-specific
  convention to port).
- The `Blocked On` gate is preserved or explicitly re-justified — this
  ticket does not promote itself to `READY_FOR_ENGINEERING` by existing.
