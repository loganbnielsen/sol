# Pre-alpha workstreams

**As of:** 2026-10-03, `main @ 7dd4ae96`.
**Purpose:** the execution/coordination layer over the ticket tree. A stream is a
coherent outcome with its own dependency shape; it says what depends on what,
what blocks alpha, and what can run in parallel. It does **not** replace tickets
— each ticket remains the unit of work and its state lives in the ticket
directory (`BACKLOG/`, `READY_FOR_ENGINEERING/`, `DONE/`).

The 2026-10-03 adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`) established every
ticket's disposition; this document groups that work. Where this document and a
ticket disagree, the ticket is authoritative for its own content.

**"Alpha"** means the current feature set is demonstrable live on a real target
with the reference application (`examples/pluto`) — the live reference-app
campaign. A **pre-alpha blocker** is work without which that demonstration would
be wrong, unsafe, or unqualified. Everything else can happen after alpha.

## Stream map

| Stream | Outcome | Pre-alpha blockers | Can start now |
|---|---|---|---|
| **S1** Production security & transport | Authenticated, encrypted production Kafka and identity-scoped secret projection, qualified | FEAT-093 | yes (independent) |
| **S2** Canonical contract & plan | Declarative contract is canonical; generated bindings drift-checked; `sol plan` reads the declaration | landed 2026-10-03 (FEAT-116, FEAT-053, DEC-065) | TS binding is a pre-S5 enabler (FEAT-129); the plan diff is FEAT-130 |
| **S3** Migration integrity & artifact/release boundaries | Applied migrations are integrity-checked; the deployer never publishes; release metadata is portable | FEAT-094, SEC-011, FEAT-110 | yes (independent) |
| **S4** Provider state & destroy semantics | Destroy converges Sol-owned targets to verified absence with bounded, evidence-based reconciliation | INFRA-082, INFRA-083, INFRA-094 | yes (independent) |
| **S5** Live alpha qualification & release readiness | The production profile and reference app are qualified end-to-end, with evidence | HARDEN-007 (gate; enablers INFRA-060/INFRA-062 landed 2026-10-03) | no — runs gated on operator authorization |
| **S6** Post-alpha parity, DX & hygiene | Framework/CI/DX quality that need not block the campaign | none | yes, but deferrable |

S1–S4 have no hard dependency on each other and can proceed in parallel. S5
consumes S1 and S4 and cannot run without an operator; S6 is post-alpha.

---

## S1 — Production security & transport

**Outcome/invariant.** The production profile's Kafka, schema-registry and admin
transport is authenticated and encrypted, workloads receive the CA and SASL
material through the declared projection, and a live workload connects over
SASL_SSL. Local/dev stays plaintext and says so.

**Tickets.**
- `FEAT-093` (READY) — Redpanda TLS + SASL, projection, registry/admin HTTPS.
  *Pre-alpha blocker.*
- `VERIF-021` (BACKLOG) — qualify AWS/GCP managed secret projection live
  (ASCP rotation, IAM denial, GKE rotation interval). *Live-blocked.*
- `VERIF-022` (BACKLOG) — qualify projected ServiceAccount tokens on aws/gcp/byo.
  *Live-blocked.*
- `VERIF-020` (BACKLOG) — the throwaway-cluster secret-projection experiment.
  *Blocked on a container runtime + authorization.*
- `SEC-005` (BACKLOG) — admission control for the deploy-identity namespace
  boundary. *Deferred against its own trigger; not a blocker.*

**Dependencies & sequencing.** FEAT-093 is the only in-repo implementation and
has no dependency on other streams. VERIF-020/021/022 need a target and come
after the profile is demonstrable (S5). SEC-005 is independent and deferred.

**Cross-stream.** FEAT-093 must land before the S5 AWS run can claim a
production-profile transport. It does not gate S2/S3/S4.

**Parallelism.** Fully parallel with S2–S4.

---

## S2 — Canonical contract & plan

**Outcome/invariant.** For the facts Sol must reason about — event/schema
identity, partitions, key semantics — the declarative contract is canonical,
language bindings are generated from it and checked in, CI fails on drift, and
`sol plan` reads the declaration directly. Code is not the source Sol parses or
executes to reconstruct intent.

**Tickets — S2 landed 2026-10-03.**
- `DEC-065` (DONE) — the decision record; closed with FEAT-116.
- `FEAT-116` (DONE) — the declarative surface, generator, checked-in
  destination, CI drift check, and the `sol plan` read (the declaration half).
- `FEAT-053` (DONE) — build-time vs runtime secret declarations exported in the
  machine-readable plan.
- `FEAT-129` (READY) — TypeScript bindings generated from the same declaration.
  *Promoted on operator review: the OCaml+TS reference-app campaign makes this a
  pre-S5 enabler, not post-alpha.*
- `FEAT-130` (BACKLOG) — record the deployed contract and report a contract change
  against it. *The plan's observed half, which FEAT-116 did not deliver; listed
  under S3 and carrying its own mechanism decision.*

**Dependencies & sequencing.** Landed: FEAT-116 implemented DEC-065 and reconciled
the two tickets it reversed or displaced — `BUG-099` (its "code is canonical"
premise is superseded; behaviour stays in code) and `FEAT-119` (verdict: keep
`contract/run` for registry reconciliation, its `--json` projection no longer used
for planning). `FEAT-130` carries the plan's observed half; `FEAT-129` carries the
TypeScript binding.

**Cross-stream.** The plan S2 produces is what S3's release metadata and S5's
runs consume, but S2 does not depend on them. ADR 0005 bounds it: the plan is the
plan of the Sol-owned boundary, not the account.

**Parallelism.** Fully parallel with S1, S3, S4.

---

## S3 — Migration integrity & artifact/release boundaries

**Outcome/invariant.** An edited already-applied migration fails the deploy gate;
the deploy identity never builds or pushes an artifact (the migration runner is
consumed pre-built, or published by the Sol release process); and release /
rollback metadata is durable, portable, and honest about its provenance.

**Tickets.**
- `FEAT-094` (READY) — per-migration checksum; `sol migrate status` reports and
  the production gate fails. *Pre-alpha blocker.*
- `SEC-011` (READY) — `sol deploy` consumes a pre-built migration-runner and
  fails closed; no deployer exception to ADR 0002. *Pre-alpha blocker.*
- `FEAT-110` (READY) — name the durable owner of release/rollback metadata and
  make it readable without Sol. *Pre-alpha contract promise (DEC-057 §9); not on
  the live-demo critical path.*
- `FEAT-130` (BACKLOG) — record the deployed event contract in the release record
  and report a contract change as `observed → desired`. *The plan's observed half
  (FEAT-116 delivered the declaration half); extends FEAT-110's record; carries an
  unresolved decision about where the observed state is read.*
- `AUDIT-077` (READY) — distinguish a stale `encoding_version` from corruption in
  release-record validation. *Small; pre-alpha diagnostic.*
- `AUDIT-075` (BACKLOG) — deployment-event actor provenance. *Deferred beyond
  maturity A.*
- `AUDIT-076` (BACKLOG) — deployment-event retention/pruning. *Deferred beyond
  maturity A.*

**Dependencies & sequencing.** SEC-011's "publish/version the runner as part of
the Sol release process" touches the distribution channel (`RELEASE-005`, S5) but
does not wait on it — the fail-closed path is implementable independently.
FEAT-110 decides whether AUDIT-075/076 are absorbed (its own text invites that);
until then they stay deferred. AUDIT-077 is independent and small.

**Cross-stream.** S5 runs exercise the migration path and the release record, so
S3's correctness is observed there; no build dependency.

**Parallelism.** Fully parallel with S1, S2, S4. Within S3, FEAT-094 and SEC-011
are adjacent (both on the migration prerequisite path) and can land together or
sequentially; FEAT-110 is independent.

---

## S4 — Provider state & destroy semantics

**Outcome/invariant.** `sol cloud destroy` converges a Sol-owned target to
positively verified absence, including when state and the provider disagree
(stale platform state under an absent substrate; a create that failed mid-apply).
Reconciliation is permitted only on provably-established provider absence —
UNKNOWN is never ABSENT — and never constructs infrastructure. A provider that
needs no authority mechanism can say so explicitly. ADR 0005 bounds all of it to
state Sol owns.

**Tickets.**
- `INFRA-082` (DONE, 2026-10-03) — absent-substrate stale platform state. *Landed: the
  platform root is read under an absent substrate and its entries forgotten — only on a
  positively established provider absence — with the evidence named in the report
  (`#997`).*
- `INFRA-094` (DONE, 2026-10-03) — convergence when the provider failed the create.
  *Landed: the same reconciliation now fires when the state still represents the cluster,
  its contents or the platform root while the provider does not have the cluster, and the
  phases that would have to reach it account for it (no release, no platform teardown, a
  preparation scoped to what is left). A cluster the provider still holds keeps the
  ordinary no-construction path (`#1002`).*
- `INFRA-083` (DONE, 2026-10-03) — the explicit total authority declaration
  (`No_authority_required | Mechanism …`) needed by DEC-051's `byo` driver. *Landed: the
  declaration is total, `with_elevated_access` skips acquisition and removal by
  construction when a provider needs no mechanism, and AWS/GCP declare the same mechanism
  they always ran (`#999`).*

**Dependencies & sequencing.** Landed in the order the stream asked for: INFRA-082, then
INFRA-094 (one mechanism across two tickets), with INFRA-083 independent. All three edit the
destroy decision layer — the two new types and the widened `deps` record — so INFRA-083, whose
PR was opened before either reconciliation landed, had to be rebased onto `main` after
INFRA-082 merged.

**Cross-stream.** S5's `INV-DESTROY-*` rows are the live qualification of this
stream; no build dependency in the other direction.

**Parallelism.** Fully parallel with S1–S3. INFRA-082/094 are one work item;
INFRA-083 is a second. **Landed 2026-10-03** — all three tickets are `DONE` and the destroy
path carries the behaviour they decided: a reconciliation that never constructs and never
fires on an absence Sol could not establish, and a total authority declaration.

---

## S5 — Live alpha qualification & release readiness

**Outcome/invariant.** The `production-single-region` profile and the reference
application are qualified end-to-end on a real target, with a reviewable evidence
bundle and independently verified teardown, and the alpha launch gate is met.

**Tickets.**
- `HARDEN-007` (BACKLOG) — AWS qualification run 9, §B3 onward. *The AWS gate;
  live-blocked on explicit authorization.*
- `HARDEN-008` (BACKLOG) — GCP attempt 10: confirm the cert-manager fix.
  *Live-blocked.*
- `PROD-001` (BACKLOG) — the maturity-A pilot and launch gate. *Live/operator
  blocked; depends on HARDEN-007 + DEC-026/027 + a named owning team.*
- `FEAT-102` (BACKLOG) — TypeScript production-profile qualification. *Blocked on
  an external `@sol-fab/worker` readiness hook + live authorization.*
- `FEAT-129` (READY) — TypeScript contract bindings generated from the declarative
  contract. *Pre-S5 enabler: the campaign qualifies the OCaml **and** TypeScript
  reference app, so the TS app must demonstrate the canonical-contract
  architecture rather than hand-declare its contract.*
- `INFRA-005` (BACKLOG) — GCP durable observability wiring. *Live-blocked on GCP
  cluster access.*
- `INFRA-060` (DONE, 2026-10-03) — qualification-only transport capability. *Landed: the
  procedure says how B3 obtains connectivity, and establishment deletes and recreates the
  access entry rather than trusting a disassociation, then verifies the effective surface.
  Its live criterion (a transaction through it, the production identities' surfaces
  unchanged) is `HARDEN-007`'s to record.*
- `INFRA-062` (DONE, 2026-10-03) — how a qualification run re-establishes a workload
  fixture. *Decision applied: teardown and recreate, written into the run procedure with
  the evidence-epoch boundary and the same `--image-ref` digests.*
- `INFRA-014` (READY) — prove the self-hosted substrate contract on a cheap
  provider. *Actionable; supports the self-hosted lane, not the AWS gate; needs a real
  cheap-provider cluster, so it is a live run.*
- `RELEASE-005` (BACKLOG) — publish the OCaml framework to public opam.
  *Deferred against its trigger (DEC-026 support promise / first external
  consumer); not required for the campaign.*

**Dependencies & sequencing.**
- `HARDEN-007 ← INFRA-060, INFRA-062` (+ `INFRA-076`) — all three now DONE, so the run is
  blocked only on authorization; and its claim of a
  production transport depends on S1's `FEAT-093`; its destroy postcondition
  depends on S4.
- `PROD-001 ← HARDEN-007` and the two decisions it names.
- `HARDEN-008` is the independent provider axis.
- `FEAT-102` is the independent language axis, and the TypeScript reference-app
  demonstration needs `FEAT-129` (generated TS bindings) first; `FEAT-129` is
  buildable now and belongs before the TS campaign, not after it.
- `INFRA-014` is independent of the AWS gate.

**Parallelism.** INFRA-060 and INFRA-062 landed 2026-10-03; everything left in this stream
is a live run, serialized against the others by cost and authorization, not by code.

---

## S6 — Post-alpha parity, DX & hygiene

**Outcome/invariant.** The framework, CI and developer experience stay coherent
after the campaign: TypeScript distribution and scaffolding, module boundaries,
guard coverage, and the mechanical cleanups the adjudication deferred.

**Tickets.** `DEC-023`, `FEAT-084` (TypeScript distribution/scaffolding),
`FEAT-037` (protocol/policy split), `INFRA-021` (CI classification),
`INFRA-065` (substring helpers), `DOCS-020` (spec signatures),
`REFAC-140`/`REFAC-141` (file splits / enforced invariants), `FEAT-114`
(operation-retry helper), `INFRA-017` (isolation characterization),
`VERIF-026` (gcloud-interface guard), and the decided no-change tickets
`FEAT-092`, `REFAC-110`, `REFAC-113` (close as bookkeeping).

**Pre-alpha blockers.** None. This stream must not gate the campaign.

**Parallelism.** All of it can proceed in parallel, and any of it can be picked
up between S1–S5 items.

---

## Standalone / not in a stream

- **Owned elsewhere:** `OBS-051` (PR #980), `BUG-125` (`sol-typescript` PR #9).
  Not actionable in this repository.
- **Deferred product surfaces with triggers:** `FEAT-043`, `FEAT-044`,
  `FEAT-048` (out of the alpha), `FEAT-058` (cluster isolation),
  `SEC-005` (admission control), `INFRA-015` (`-fn` capacity isolation). Each
  names its own objective trigger and belongs to no stream until it fires.
- **Deliberately deferred against a trigger:** `RELEASE-005` (listed in S5 but not
  needed for the campaign), `AUDIT-075`/`AUDIT-076` (listed in S3 but deferred
  beyond maturity A).

## The path to alpha

1. **Land the parallel pre-alpha blockers** — S1 `FEAT-093`; S2 landed 2026-10-03
   (`FEAT-116`, `FEAT-053`, `DEC-065`); S3 `FEAT-094`, `SEC-011`; S4 `INFRA-082`+`INFRA-094`,
   `INFRA-083` (landed 2026-10-03). These four streams are independent and can run concurrently.
2. **Prepare the qualification enablers** — **done 2026-10-03**: S5 `INFRA-060` (the
   transport, its live criterion handed to run 9) and `INFRA-062` (the fixture reset) both
   landed. (S3 `FEAT-110`, `AUDIT-077` can land in this window.)
3. **Run the live qualification** once the operator authorizes it — S5
   `HARDEN-007` (AWS), `HARDEN-008` (GCP), with S1 and S4 already landed.
4. **Hold the launch review** — S5 `PROD-001`, the maturity-A gate.
5. **Everything else (S6) after alpha.**

## Reconciliation candidates (proposed, not yet applied)

These ticket changes were applied on 2026-10-03, after operator sign-off.

1. **Applied — closed `FEAT-092`, `REFAC-110`, `REFAC-113`** (non-goal /
   no-change), each with a closing note. `docs/architecture/observability-design.md`
   now states the alert-inventory non-goal and no longer names FEAT-092 as an open
   gap.
2. **Applied — `INFRA-062` resolved to option 3 (fixture teardown and recreate)**,
   on architectural grounds: DEC-039 places fixture mechanics with the harness,
   the qualification epoch must keep the same artefact, and B2 must not be
   weakened. Option 1 changes the artefact; option 2 (an explicit Sol restart
   capability) is a separate, undecided product question and is not created. The
   ticket's implementation was the run-procedure update, and it landed on
   2026-10-03 (`INFRA-062`, DONE); "fixture teardown" resolves to the target-level
   `sol cloud destroy` because a namespace-scoped teardown is not expressible on
   Sol's surfaces or under DEC-039's identity model.
3. **Applied — `INFRA-082` → `INFRA-094` sequenced as one reconciliation unit**
   (INFRA-082 first), recorded in both tickets.
4. **Applied — `FEAT-116` carries the `FEAT-119`/`BUG-099` reconciliation** in its
   scope; a follow-up is filed only if the `contract/run` verdict needs one.
5. **Applied — `FEAT-110` must settle the fate of `AUDIT-075`/`AUDIT-076`** and
   record absorb-or-keep in its completion notes.
6. **No change — `FEAT-043`/`FEAT-044`/`FEAT-048`** already carry their
   out-of-alpha triggers.

