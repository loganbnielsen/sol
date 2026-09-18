---
id: INFRA-030
type: bug
severity: high
title: The production profile must declare a platform capacity contract, not inherit a node shape
source: HARDEN-002 Run 5 attempt 1, 2026-09-18 — live non-conformant run against a
  real AWS target
---

**Depends on:** None.

**Related:** DEC-026 §3/§4 (availability and headroom), AUDIT-080
(`node_failure_headroom_nodes`), FEAT-089 (preflight), HARDEN-002 (the run that found
this), INFRA-028/INFRA-029 (the lifecycle this blocked reaching `Ready`).

## What happened (live, Run 5 attempt 1)

A fresh `production-single-region/v1` target provisioned its cloud substrate
successfully and then **could not install the platform**:

```
helm_release.redpanda: context deadline exceeded
helm_release.loki[0]:  context deadline exceeded
0/3 nodes are available: 3 Insufficient cpu.
```

Measured cause:

| | value |
|---|---|
| node group | `node_instance_types = ["m6i.large"]` (2 vCPU each), `node_desired_size = 3` |
| cluster capacity | **6 vCPU** / 24 GiB |
| the platform's own Redpanda (RF≥3) alone | **3 × 2 vCPU = 6 vCPU** / 12 GiB |
| also Pending | `loki-chunks-cache-0` |

Both shape values are **module defaults** (`cli/platform/infra/aws/variables.tf`), and
the profile sets neither. So the platform's own required components consume the entire
qualified substrate, and a default production target can never reach `Ready`.

## Why a bigger default is not the fix

Bumping the default to `m6i.xlarge` repairs today's manifestation and leaves the defect
class intact: anyone can set `node_instance_types = ["m6i.large"]`,
`node_desired_size = 3` and again have a target that satisfies
`production-single-region/v1` while being structurally unable to run the production
platform. The profile makes a stronger claim than "a shape was chosen" — it claims the
target has enough capacity to host the production platform contract. That claim has to
be mechanically checkable.

## The invariant

> A target conforming to `production-single-region/v1` must not be structurally
> unschedulable under the platform's own declared resource requirements, including its
> required node-failure headroom. Preflight must reject configurations that provably
> violate this contract. The contract describes **capacity**, not a particular AWS
> instance type.

Three separable things, which the fix keeps separate:

1. **The contract** — the platform's declared resource envelope plus the profile's
   minimum capacity/headroom requirement.
2. **The recommended shape** — one configuration that comfortably satisfies it.
3. **Live qualification** — HARDEN-002 proving the resulting target actually reaches
   `Ready` (Run 5 attempt 2).

## Deliberately not a scheduler simulation

Aggregate request summation is a *lower bound*, not schedulability: 12 vCPU total does
not schedule a 4-vCPU pod if no single node has 4 vCPU free, and DaemonSets, system
reservations, affinity/anti-affinity and topology constraints all bite. Note that this
run failed **both** per-node (a 2-vCPU node cannot host a 2-vCPU pod — allocatable is
below capacity once system pods take their share) and in aggregate. The contract is
therefore expressed as conservative, checkable rules rather than a pretend scheduler:

- **per-node floor** — the platform's largest indivisible pod request must fit on one
  node's allocatable capacity;
- **cluster floor after headroom** — the platform's total request must fit on
  `node_desired_size - node_failure_headroom_nodes` nodes, not merely on all of them.
  This is the part that matters: production promises tolerance of a node disappearing,
  so "fits on N" is the wrong question and "fits on N − headroom" is the right one.

## Remediation

- add a `platform_capacity` capability to the profile vocabulary
  (`Sol_cli_profile.capability`), so the claim appears in the preflight report like
  every other guarantee rather than being implicit in a Terraform default;
- declare the platform's resource envelope as **data** in one place, derived from the
  platform charts' own requests, with the derivation recorded next to it;
- declare the profile's recommended node shape as data and state it satisfies the
  envelope;
- **enforce by construction**: the production profile contributes the node-shape
  Terraform variables through the existing profile-precedence path
  (`vars_with_profile_precedence`, the mechanism that already stops a caller weakening
  `rds_multi_az` / `rds_deletion_protection`), so no target or `-var` can silently
  undersize a profile target;
- **reject what can still violate it**: `node_failure_headroom_nodes` is a *target*
  field, so preflight must refuse a headroom that leaves the platform unschedulable
  (headroom ≥ effective node count, or capacity-after-headroom below the envelope) and
  name the shortfall;
- keep the chosen shape as a *recommendation*, so a future qualified shape is a data
  change, not a contract change.

## Acceptance criteria

- The exact Run 5 attempt 1 shape (3 × 2-vCPU nodes) is **rejected** by an offline test,
  with the reason naming the per-node and/or aggregate shortfall.
- A target declaring `node_failure_headroom_nodes` that cannot leave the platform
  schedulable is rejected by preflight.
- The profile's recommended shape satisfies the envelope, and an offline test pins that
  relationship so a reduced shape or a raised platform request fails the build instead
  of failing a live run.
- A non-profile target keeps full operator control of its node shape and makes no
  capacity claim (unchanged behaviour).
- No live AWS resource is required to evaluate the contract: this is a pure,
  offline-testable function plus preflight wiring.
- The preflight report lists `platform_capacity` alongside the other guarantees, so an
  operator can see the claim and its basis.

**Demo/example coverage:** the production-profile example target
(`examples/pluto/sol/pilot/aws/us-east-1.yml`) gains nothing to declare — the contract
is enforced by the profile, which is the point. Update the production bootstrap /
qualification docs where they describe the node shape as an operator choice.

**TypeScript parity:** No language-parity impact.
