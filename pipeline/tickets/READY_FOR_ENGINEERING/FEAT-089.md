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
