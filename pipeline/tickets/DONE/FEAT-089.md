---
id: FEAT-089
type: feature
severity: high
title: Implement production profile selection, validation and evidence identity
source: DEC-026 implementation owner identified during maturity-A backlog reconciliation
---

**Depends on:** DEC-026, DEC-027.

## Production guarantee

A team opts into a specific, versioned production contract deliberately, and Sol
rejects a target whose capabilities or evidence cannot satisfy the application's
portable requirements before any mutation occurs.

DEC-026 defines the contract. This ticket implements the shared profile seam in
the existing target -> typed plan -> render/executor pipeline; individual
availability, durability, state/access and operations tickets implement their
own capability checks.

## Implementation scope

- Add explicit profile selection to target configuration, independent of the
  environment name.
- Carry profile identity and portable application requirements through the typed
  plan without adding provider/Kubernetes mechanism fields to application
  configuration.
- Collect target capabilities/policy from the selected target implementation.
- Validate compatibility once, before render/apply, and report the unmet Sol
  guarantee plus the responsible target/application side.
- Define the stable profile/evidence identity consumed by HARDEN-002.
- Keep one profile only; no profile inheritance, plugin system or policy DSL.

## Acceptance criteria

- A target named `prod` with no profile selected receives no production claim.
- A target explicitly selecting the supported profile and satisfying its
  capabilities produces a plan containing the profile/version and evidence
  requirements.
- An incompatible application/target pair fails before infrastructure or cluster
  mutation and names the unmet semantic without requiring the user to understand
  raw Kubernetes/provider settings.
- Dry-run, direct/GitOps output and recorded releases preserve the selected
  profile identity consistently according to DEC-027.
- Adding an unrelated environment value cannot silently opt into or weaken the
  profile.

**Implementation versus evidence:** This ticket implements selection and
validation. HARDEN-002 proves the profile's individual guarantees on a live
target.

**Demo/example coverage:** Add one conformant production target and one readable
incompatible-target example showing the preflight failure.

**TypeScript parity:** The profile operates on portable workload requirements and
must not inspect language-specific build metadata.

## Completion notes (2026-09-17)

**Premise verified before starting:** on `main` at 3368f3b7, neither
`Sol_cli_config`'s target key vocabulary nor `Sol_cli_deployment_plan.t` had any
profile concept, so the work was still missing.

**What shipped:**

- **Selection.** Target files accept `profile: production-single-region`.
  `sol.yml` may not set it, because its `target:` section is inherited by every
  target. Unknown values are rejected.
- **Plan.** `Sol_cli_deployment_plan.t.profile` carries the profile identity
  (`production-single-region/v1`) and the guarantees it requires for the plan's
  workloads. The plan JSON emits them as `evidence_requirements`.
- **Validation.** `Sol_cli_profile_preflight` runs once, in `sol deploy`'s
  `build_plan`, which every path (dry-run, `--emit-to`, apply) goes through
  before any cluster call, lease or emitted file.
  - It establishes the qualified provider (AWS) and direct apply authority
    (`--emit-to` is refused, per DEC-027).
  - Every other guarantee reports as unmet with Sol responsible, so the profile
    fails closed on every target for now.
- **Recording.** The deployment event records the claim; the release record
  does not. See the DEC-026 correction, made in this PR.
- **Vocabulary.** Guarantees are platform capabilities
  (`immutable_artifacts`, `remote_state`, …), never ticket ids.

**Acceptance criteria:**

- *A target named `prod` with no profile gets no production claim.* Tested.
- *A conformant target produces a plan with the profile, version and evidence
  requirements.* Proven in unit tests with every guarantee stubbed as
  established. No real target can conform until the remaining guarantee
  tickets land; that is DEC-026's fail-closed invariant, not a gap here.
- *An incompatible target fails before mutation, naming the unmet guarantee.*
  Covered by unit tests plus a CLI `runtest` rule. The rule proves:
  - `--emit-to` writes no files;
  - apply refuses before any cluster call.
  Both the unit tests and the CLI rule were mutation-checked.
- *Dry-run, direct/GitOps output and recorded releases stay consistent with
  DEC-027.*
  - Dry-run and direct apply carry the same claim.
  - GitOps output is refused for a profile target.
  - Release identity is provably unchanged by selecting a profile (tested).
- *An unrelated environment value cannot opt a target in or weaken it.* Tested.

**Handed off:**

- DEC-026 §2's TypeScript rejection has no language-neutral signal to check.
  Recorded on FEAT-088, which must define an explicit compatibility input.
- A worker counts as Kafka use, because the plan cannot tell a
  `sol-jobs`-only worker apart from a Kafka consumer. This is the fail-closed
  direction, and it matches DEC-026 §3's open question about non-Kafka workers.
- `sol rollback` runs no profile preflight. Deciding which releases are
  compatible to restore on a profile target stays with AUDIT-069 and FEAT-050,
  which can now read the claim from deployment events.

**Demo/example coverage:**

- Added `examples/pluto/sol/pilot/aws/us-east-1.yml`, a readable incompatible
  target whose dry-run shows the refusal, plus a README section.
- Pluto's `prod` target deliberately still claims nothing.
- The conformant-target example is deferred to HARDEN-002/PROD-001, which
  already own the reference example: no target can conform until the remaining
  guarantees exist.

**TypeScript parity:** No language-specific impact. The profile reads only
portable plan data (primitives, declared resources, topics, migrations) and
never build metadata.
