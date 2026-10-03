# BACKLOG adjudication — pre-alpha, 2026-10-03

**Scope:** every ticket in `internal/pipeline/tickets/BACKLOG/` (47) plus the
8 open `READY_FOR_ENGINEERING/` tickets, against `origin/main @ e3d00235`.
**Owner:** the pre-alpha backlog adjudication pass, run before the live
reference-app campaign.

The pass exists to remove *unprioritized* as a ticket state: after it, every
ticket is either actionable and owned, closed with evidence, explicitly deferred
against an objective trigger, or concretely blocked on a live/operator input.
Age, size, cross-repository scope and "requires a decision" are not dispositions.

**Method.** Each ticket was read in full and its premise re-checked against
current `main` where the check is cheap: `soldev pipeline ls` (which evaluates
`premise:` probes), direct `rg`/file probes of the named code, and the state of
every ticket it depends on. Premises that had already been satisfied, decisions
that a later ticket re-decided, and tickets whose subject no longer exists are
closed rather than left to mislead the next reader. `owner` is `this pass` for
work this pass implements, `external` where another actor/repository owns it.

## Disposition summary

| Ticket | Disposition | Why |
|---|---|---|
| BUG-035 | **Closed** | Premise stale — the two Pluto target files no longer exist; the probe succeeds. |
| BUG-065 | **Closed** | Superseded — VERIF-005 deleted the guard this ticket would extend. |
| DEC-043 | **Closed** | Resolved by DEC-057; INFRA-096 (implementer) is DONE. |
| DEC-044 | **Closed** | Superseded by DEC-045 + REFAC-094; B2/A1 deleted, DOCS-022 recorded. |
| EXP-025 | **Closed** | Superseded by EXP-031 (DONE); ticket says "work EXP-031 instead". |
| FEAT-095 | **Closed** | Withdrawn — FEAT-113 removed the OCaml contract it wanted TS to match. |
| INFRA-087 | **Closed** | Withdrawn — FND-0060 falsified; real defect is INFRA-088 (DONE). |
| AUDIT-077 | **Actionable** | `validate` still reports "corrupt"; small diagnostic fix. |
| DOCS-020 | **Actionable** | Guard manifest still covers only 2 of 6 specs. |
| FEAT-037 | **Actionable** | Protocol/policy split still absent; premise refreshed 2026-10-02. |
| FEAT-053 | **Actionable** | No build-time/runtime secret split in `sol.toml`. |
| FEAT-110 | **Actionable** | Release/rollback metadata portability is an open DEC-057 §9 promise. |
| FEAT-114 | **Actionable** | Retry vocabulary exists only inside `sol-jobs`; no shared helper. |
| INFRA-021 | **Actionable** | Classifier still only `docs-only|source`. |
| INFRA-065 | **Actionable** | 49 `contains` helpers, four signatures — premise holds. |
| INFRA-081 | **Actionable** | `preparations_eligible` still string-compares instanced addresses. |
| OBS-051 | **Actionable** | TS demo does not read `SOL_*`; in-repo half is doable now. |
| REFAC-140 | **Actionable** | Banner seams remain in the files the ticket lists. |
| REFAC-141 | **Actionable** | Comment-stated invariants are still prose-only. |
| FEAT-043 | **Decision required** | Is analytics/warehouse export core, connector, or out of scope? |
| FEAT-044 | **Decision required** | Is a cache primitive in scope, and against what demand evidence? |
| FEAT-048 | **Decision required** | Edge/Cloudflare: build the Tunnel slice, or declare a non-goal? |
| FEAT-092 | **Decision required** | Build a scope-aware alert view, or declare it a non-goal? |
| FEAT-093 | **Decision required** | Is in-cluster plaintext Kafka an accepted production posture? |
| FEAT-094 | **Decision required** | Should an edited applied migration fail the gate or warn? |
| FEAT-116 | **Decision required** | How does `sol plan` inspect contracts declared in code? |
| INFRA-082 | **Decision required** | Destroy semantics when cloud root is gone but platform state is not. |
| INFRA-083 | **Decision required** | Shape of an explicit "provider needs no authority" declaration. |
| INFRA-094 | **Decision required** | Destroy semantics when a provider-create failed mid-apply. |
| SEC-011 | **Decision required** | Is Sol's migration-runner image an application artifact? (ADR 0002) |
| REFAC-110 | **Decision required** | Is removing the last `chdir` worth its regression surface? |
| REFAC-113 | **Decision required** | Adopt `bos`/`spawn`, or keep the hand-rolled process module? |
| AUDIT-075 | **Deferred (trigger)** | Trigger: team/CI-shared deployment attribution (maturity B). |
| AUDIT-076 | **Deferred (trigger)** | Trigger: measurable ConfigMap growth or a cross-cluster retention need. |
| FEAT-058 | **Deferred (trigger)** | Four explicit triggers in the ticket (Sol-owned creds, two envs/cluster, observed mis-resolution, shared kubeconfig). |
| SEC-005 | **Deferred (trigger)** | Trigger: a second driver for an admission-control layer (customer compliance / compromised-credential threat model). |
| INFRA-015 | **Deferred (trigger)** | Trigger: larger-scale or memory/CPU-throttling evidence that `-fn` bursts interfere. |
| RELEASE-005 | **Deferred (trigger)** | Trigger: DEC-026's support promise is extended to include public-opam availability, or the first external consumer needs it. |
| FEAT-102 | **Live/operator blocked** | Needs an external `@sol-fab/worker` readiness hook + live-profile authorization. |
| HARDEN-007 | **Live/operator blocked** | Needs explicit authorization for a live, billable AWS run. |
| HARDEN-008 | **Live/operator blocked** | Needs explicit authorization for a live GCP run. |
| PROD-001 | **Live/operator blocked** | Needs a qualified profile + a named owning team + a real workload. |
| VERIF-020 | **Live/operator blocked** | Needs a machine with a working container runtime + authorization. |
| VERIF-021 | **Live/operator blocked** | Needs a live AWS/GCP target + authorization. |
| VERIF-022 | **Live/operator blocked** | Needs a live target per driver + authorization. |
| INFRA-005 | **Live/operator blocked** | Needs live GCP cluster access to validate the GCS wiring. |
| BUG-125 | **Owned externally** | Fix is in `sol-typescript`; PR #9 open on `BUG-125/jobs-renewal-timer`. |

## Category-5 decisions (operator input needed)

These are genuine product/security/architecture forks: the evidence permits
materially different answers, and the choice changes what Sol means. Each is
stated as the smallest decision plus its consequences. They are not deferred —
they are waiting on an operator answer, and the surrounding actionable tickets
continue independently.

1. **FEAT-093 — Kafka production transport.** Accept in-cluster plaintext behind
   NetworkPolicy as the production posture (close FND-0039 ACCEPTED), or require
   SASL_SSL (Redpanda TLS via cert-manager + SASL creds rendered into workloads).
   *Consequence:* accepting keeps the current SEC-007 posture and is a
   qualification row only; requiring it is a cross-cutting change to the
   durable platform values, manifest rendering, the compatibility matrix and
   every live run.
2. **FEAT-092 — alert applicability view.** Build a scope-aware view over the
   identity labels (resolving owner/runbook), or declare it a non-goal (Grafana/
   Alertmanager own rendering) and close via DOCS-019.
   *Consequence:* build adds a `sol status`/axis surface and a demo obligation;
   non-goal is a documentation change.
3. **FEAT-116 — inspecting code-declared contracts.** Choose a mechanism:
   build-time metadata artifact, `sol inspect`-style command, generated manifest
   metadata, or manifest + drift guard. Writing it into `events/<team>/sol.toml`
   is already rejected by BUG-099.
   *Consequence:* each option changes where the canonical contract lives and how
   both languages expose it (DEC-022).
4. **FEAT-043/044/048 — product surface expansion.** Whether Sol grows an
   analytics-warehouse export surface (FEAT-043), a first-class cache component
   (FEAT-044), and an edge (Cloudflare Tunnel) axis (FEAT-048).
   *Consequence:* each is a second product surface with its own compute, cost and
   compliance ownership; declaring them out of the alpha is equally valid.
5. **FEAT-094 — migration checksum.** Fail the deploy gate on an edited applied
   migration (Flyway-style), or warn.
   *Consequence:* fail-closed may block a legitimate repeatable edit; warn keeps
   a silent divergence.
6. **INFRA-082 / INFRA-094 — destroy semantics for a partially-created or
   diverged target.** Accept the state as inert bookkeeping and document the
   unmet postcondition, or add a supported, explicit reconciliation path
   (extending the INFRA-042 "forget what provably cannot exist" rule to the
   absent-substrate and failed-create cases). *Constraint:* non-construction stays
   the invariant; DEC-057 excludes installation resources.
   *Consequence:* accepting leaves a destroy postcondition that cannot be met;
   reconciling adds a state-truth mechanism with its own evidence rule.
7. **INFRA-083 — explicit "no authority" capability.** Make the declaration total
   (`No_authority_required | Mechanism …`), or reject ambiguous declarations at
   construction. *Consequence:* DEC-051's `byo` driver and DEC-057's
   provider-symmetry requirement both need one of these.
8. **SEC-011 — the migration-runner image and ADR 0002.** Treat Sol's own runner
   image as an application artifact (route checkout-mode deploys to a published
   runner, refuse without one), or record the deployer exception in ADR 0002 and
   the boundary guard.
9. **REFAC-110 / REFAC-113 — internal engineering choices.** Remove the last
   process-wide `chdir` (119 sites) or keep the single-entry-point convention;
   adopt `bos`/`spawn` or keep the hand-rolled `Sol_cli_process`. These are
   reversible refactors, but both tickets are framed as decisions and the
   operator's preference sets the direction.

## What this pass changes in the tree

- The seven closed tickets move `BACKLOG/ → DONE/`, each carrying a
  `## Disposition (2026-10-03)` section with the evidence.
- Every ticket remaining in `BACKLOG/` carries a `## Disposition (2026-10-03)`
  section naming its category and, for the deferred ones, the objective trigger.
- Actionable tickets are promoted to `READY_FOR_ENGINEERING/` by a follow-up
  triage commit once this pass has finished implementing the ones it can.
