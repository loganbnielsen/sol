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
| **S2** Canonical contract & plan | Declarative contract is canonical; generated bindings drift-checked; `sol plan` sees contracts | FEAT-116 (+DEC-065) | yes (independent) |
| **S3** Migration integrity & artifact/release boundaries | Applied migrations are integrity-checked; the deployer never publishes; release metadata is portable | FEAT-094, SEC-011, FEAT-110 | yes (independent) |
| **S4** Provider state & destroy semantics | Destroy converges Sol-owned targets to verified absence with bounded, evidence-based reconciliation | INFRA-082, INFRA-083, INFRA-094 | yes (independent) |
| **S5** Live alpha qualification & release readiness | The production profile and reference app are qualified end-to-end, with evidence | HARDEN-007 (gate), INFRA-060, INFRA-062(-decision) | partly (enablers yes; runs gated on operator) |
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

**Tickets.**
- `DEC-065` (BACKLOG) — the decision record. *Closes with FEAT-116.*
- `FEAT-116` (READY) — the declarative surface, generator, checked-in
  destination, CI drift check, and the `sol plan` read. *Pre-alpha blocker.*
- `FEAT-053` (READY) — build-time vs runtime secret declarations exported in the
  machine-readable plan. *Shares the plan-emission surface; otherwise
  independent; pre-alpha.*

**Dependencies & sequencing.** FEAT-116 implements DEC-065. It must reconcile two
DONE tickets it reverses or displaces:
- `BUG-099` (DONE) — its "code is canonical" premise is reversed; the contract is
  now canonical and the code generated from it.
- `FEAT-119` (DONE) — decide whether the `contract/run` projection remains
  necessary or folds into the generated-bindings mechanism. DEC-065 requires the
  verdict on the record; this may become a small follow-up ticket.

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
- `INFRA-082` (READY) — absent-substrate stale platform state. *Pre-alpha
  blocker.*
- `INFRA-094` (READY) — convergence when the provider failed the create.
  *Pre-alpha blocker.*
- `INFRA-083` (READY) — the explicit total authority declaration
  (`No_authority_required | Mechanism …`) needed by DEC-051's `byo` driver.
  *Pre-alpha.*

**Dependencies & sequencing.** INFRA-082 and INFRA-094 share the same mechanism
(extend INFRA-042's "forget what provably cannot exist" to a broader provable
absence) and should be implemented as one unit or back-to-back, INFRA-082 first.
INFRA-083 is the capability-declaration half and is independent, though it also
touches the destroy bracket (`with_elevated_access`) and should land with its
tests on both sides.

**Cross-stream.** S5's `INV-DESTROY-*` rows are the live qualification of this
stream; no build dependency in the other direction.

**Parallelism.** Fully parallel with S1–S3. INFRA-082/094 are one work item;
INFRA-083 is a second.

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
- `INFRA-005` (BACKLOG) — GCP durable observability wiring. *Live-blocked on GCP
  cluster access.*
- `INFRA-060` (READY) — qualification-only transport capability. *Actionable
  enabler; no cloud access needed to build it.*
- `INFRA-062` (READY) — how a qualification run re-establishes a workload
  fixture. *Has an unresolved decision; see "Reconciliation candidates".*
- `INFRA-014` (READY) — prove the self-hosted substrate contract on a cheap
  provider. *Actionable; supports the self-hosted lane, not the AWS gate.*
- `RELEASE-005` (BACKLOG) — publish the OCaml framework to public opam.
  *Deferred against its trigger (DEC-026 support promise / first external
  consumer); not required for the campaign.*

**Dependencies & sequencing.**
- `HARDEN-007 ← INFRA-060, INFRA-062` (+ `INFRA-076`, DONE), and its claim of a
  production transport depends on S1's `FEAT-093`; its destroy postcondition
  depends on S4.
- `PROD-001 ← HARDEN-007` and the two decisions it names.
- `HARDEN-008` is the independent provider axis.
- `FEAT-102` is the independent language axis.
- `INFRA-014` is independent of the AWS gate.

**Parallelism.** INFRA-060 and INFRA-062's decision can proceed now and are the
only parts that do not need an operator. The runs themselves are serialized
against each other by cost and authorization, not by code.

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

1. **Land the parallel pre-alpha blockers** — S1 `FEAT-093`; S2 `FEAT-116`
   (+`FEAT-053`); S3 `FEAT-094`, `SEC-011`; S4 `INFRA-082`+`INFRA-094`,
   `INFRA-083`. These four streams are independent and can run concurrently.
2. **Prepare the qualification enablers** — S5 `INFRA-060`, and resolve
   `INFRA-062`'s decision. (S3 `FEAT-110`, `AUDIT-077` can land in this window.)
3. **Run the live qualification** once the operator authorizes it — S5
   `HARDEN-007` (AWS), `HARDEN-008` (GCP), with S1 and S4 already landed.
4. **Hold the launch review** — S5 `PROD-001`, the maturity-A gate.
5. **Everything else (S6) after alpha.**

## Reconciliation candidates (proposed, not yet applied)

These are ticket changes that follow from the 2026-10-03 decisions and this
organization. None has been made; each needs sign-off.

1. **Close `FEAT-092`, `REFAC-110`, `REFAC-113`.** All three are decided —
   non-goal / no-change — and only need the READY → DONE transition with a closing
   note (FEAT-092 also wants `DOCS-019`'s document to state the non-goal).
2. **`INFRA-062` is in `READY_FOR_ENGINEERING` with an unresolved `## Decision
   needed` section**, which violates the rule that READY tickets are actionable.
   Either resolve the decision now (option 1 "new revision" is the smallest
   change and preserves B2's idempotence contract), or demote it to `BACKLOG`.
3. **`INFRA-082` and `INFRA-094` share one mechanism.** Keep both tickets but
   sequence them as one implementation unit (INFRA-082 first), and say so in
   each.
4. **`FEAT-116` must reconcile `FEAT-119` and `BUG-099`.** Add the reconciliation
   to FEAT-116's scope, and file the small follow-up only if the `contract/run`
   verdict needs its own unit.
5. **`FEAT-110` decides the fate of `AUDIT-075`/`AUDIT-076`** (its own text invites
   absorbing them); record absorb-or-keep in FEAT-110's completion notes.
6. **`FEAT-043`/`FEAT-044`/`FEAT-048`** already carry their out-of-alpha triggers;
   no further change.
