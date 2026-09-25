# ADR 0003: Lifecycle phases determine authority and desired-state policy

- **Status:** Accepted
- **Date:** 2026-09-18
- **Scope:** the `sol cloud apply` / `sol cloud destroy` lifecycle for AWS
  `production-single-region/v1`; the phase vocabulary is provider-neutral
- **Supersedes:** the "temporary cluster-admin only to create the custom RBAC"
  and "apply always reconciles back toward protected Ready state" wording in
  ADR 0002

## Context

HARDEN-002 runs 3 and 4 exercised the public lifecycle against fresh AWS targets
and surfaced six defects. Three were ordinary transition/wiring bugs. The other
three had a single root cause that the earlier design did not model:

- **Finding 13** — the steady-state cluster-access identity could not create the deploy
  identity's `sol-deploy` ClusterRole, because Kubernetes' RBAC
  privilege-escalation check forbids granting permissions the creator does not
  hold.
- **Finding 14** — the same check rejected third-party chart RBAC (the
  prometheus chart's `prometheus-server` ClusterRole) during the full platform
  apply, which ran *after* the temporary cluster-admin association had been
  removed.
- **Finding 15** — `sol cloud destroy` prepared destruction (deletion protection
  off, unique final snapshot, verified) and then re-applied ordinary production
  desired state before destroying, restoring `rds_deletion_protection=true` and
  stranding the instance.

Findings 13/14 showed the creation side de-escalated too early, because it had
not modelled *when the privileged installation phase ends*. Finding 15 showed
the destruction side re-entered ordinary reconciliation after leaving steady
state, because it had not modelled *that the desired-state policy changes*.
Both are the same missing concept: two individually-correct rules —

```
BUG-039    production-single-region/v1 -> RDS deletion protection = true
INFRA-023  PrepareDestroy              -> RDS deletion protection = false
```

— contradicted each other only because nothing said which rule was in force.

## Decision

The lifecycle is an explicit sequence of phases. A phase determines **the
authority Sol may use** and **the desired-state policy that applies**. The phase
record (see "not infrastructure truth" below) is derived from the command and
its verified preparation; it is never persisted as a second state database.

```
Absent
  | bootstrap
  v
CloudBootstrap          temporary privileged authority
  | establish substrate + access
  v
PlatformInstalling      privileged platform installation
  | CRDs / RBAC / charts
  v
Verify
  |
  v
De-escalate
  |
  v
Ready                   bounded steady-state cluster-access identity
  |
  +---- platform change requiring privilege ----+
  |                                             v
  |                                     PlatformUpdating
  |                                             |
  |                                      verify + revoke
  |                                             |
  +<--------------------------------------------+
  |
  | destroy
  v
PreparingDestroy        destroy policy; Ready policy no longer applies
  |
  v
Destroying
  |
  v
Absent
```

| Phase | Authority | Desired-state policy | Allowed mutation |
| --- | --- | --- | --- |
| `CloudBootstrap` | temporary privileged | Bootstrap | establish substrate / access |
| `PlatformInstalling` | explicitly privileged installation authority | Installation | CRDs / RBAC / charts |
| `Ready` | bounded provisioner | Production | normal reconciliation |
| `PlatformUpdating` | temporarily privileged installation authority | Installation | privileged platform change, then revoke |
| `PreparingDestroy` | explicit destroy authority | Destroy | disable protection / finalize |
| `Destroying` | destroy authority | Destroy | Terraform destruction |

The policy of a phase is fixed: `Bootstrap` for `CloudBootstrap`,
`Installation` for `PlatformInstalling`/`PlatformUpdating`, `Production` for
`Ready`, `Destroy` for `PreparingDestroy`/`Destroying`.

### Invariants

1. **The privileged installation authority spans the whole platform install.**
   Installing cluster-wide software that mints RBAC *is* privileged platform
   establishment. `PlatformInstalling` keeps the temporary cluster-admin
   association open through the full platform apply **and** verified readiness;
   the association is revoked only at the verified `PlatformInstalling -> Ready`
   transition, after which the bounded steady-state cluster-access identity is verified
   effective. (This supersedes ADR 0002's "only long enough to create the custom
   RBAC".)
2. **The steady-state cluster-access identity is never privilege-escalatable.**
   It holds no Kubernetes `escalate`/`bind` verb on
   `clusterroles`/`clusterrolebindings`, and its IAM policy denies EKS
   access-entry/policy-association and all IAM mutation. The separate
   cloud-provisioning identity owns those cloud mutations. The cluster-access
   identity cannot create chart RBAC — which is exactly why invariant 1 exists.
   A future failing apply must be fixed by using the privileged phase, never by
   widening the steady-state identity.
3. **A privileged platform change is an explicit re-entry into `PlatformUpdating`,**
   not an implicit widening of `Ready`. The elevated authority is granted for
   the operation and revoked again after verification.
4. **Once `PreparingDestroy` has been verified, Ready policy must not run again**
   before destruction. Any reconciliation in `PreparingDestroy`/`Destroying`
   applies the Destroy policy, so the Production invariant
   (`rds_deletion_protection = true`, BUG-039) is deliberately not in force even
   though it remains exactly correct throughout `Ready`.
5. **Illegal forward transitions are rejected.** The forward relation
   (`transition_allowed`) admits only the edges in the diagram; in particular
   `PreparingDestroy -> Ready` and `PrepareDestroy`-then-Ready-policy are
   structurally impossible.

6. **A failed or partially installed target is always destructible.** Lifecycle
   enforcement must never strand infrastructure. Destruction is therefore *not* a
   forward transition but an **abort edge** (`destruction_available`): available
   from every phase that can hold infrastructure — `CloudBootstrap`,
   `PlatformInstalling`, `Ready`, `PlatformUpdating` — and also from
   `PreparingDestroy`/`Destroying` themselves, so an interrupted destroy can be
   resumed. Only `Absent`, the post-destroy state, has nothing to tear down, and
   destroying an absent target yields that state, which is why destroy is
   idempotent rather than an error.

   The two are kept apart on purpose. Folding the abort edge into the forward
   relation would stop the relation from meaning "the diagram"; routing
   destruction *through* the forward relation would refuse to tear down a
   half-built target, leaving manual surgery on live cloud resources as the only
   exit — the outcome this invariant exists to prevent. Destruction also observes
   deliberately less than apply: the abort edge returns the same answer for
   `Ready` and `PlatformInstalling`, so a destroy decides only Absent-ness, and
   never depends on a probe that could fail and block teardown.

### The phase record is not infrastructure truth

A phase names the operation/transition Sol is performing right now. It is *not*
a stored description of the world:

- Terraform state remains authoritative for the resources each root manages;
- AWS and Kubernetes provide observed reality, and readiness is observed, never
  inferred from the phase;
- no phase-pointer file or second infrastructure state database is introduced
  (ADR 0002 already rejected one). The phase is recomputed each run from the
  command and its verified preparation.

## Implementation

The phase and policy vocabulary lives in `Sol_cli_cloud_lifecycle` (`phase`,
`phase_policy`, `policy_of_phase`, `transition_allowed`, `destruction_available`,
`enter_destruction`, `ready_policy_applies`, `policy_vars`). The operations in
`cli/bin/cmd_cloud_tf.ml` perform only legal transitions -- forward progress
through `enter`, which refuses any edge `transition_allowed` rejects, and entry to
destruction through `enter_destruction`, the abort edge of invariant 6 -- and
`policy_vars` supplies the phase's desired-state overrides, appended after caller
variables so the phase policy wins.

`sol cloud destroy` derives its phase from `enter_destruction` rather than
asserting `PreparingDestroy` directly. That is what makes the model and the
operation agree: before, the operation was legal from any state while the relation
said the edge was not.

Regression coverage asserts the semantics, not just the original bugs:

- unit tests assert the forward relation (including the rejected
  `PreparingDestroy -> Ready` *and* the rejected
  `PlatformInstalling -> PreparingDestroy`), that the abort edge nevertheless
  admits every phase except `Absent`, that destroying never lands in a
  Ready-policy phase, and that Destroy policy overrides the Production invariant;
- the offline lifecycle harness asserts the full platform apply happens **before**
  the provisioner is de-escalated, that the post-prepare bootstrap-admin apply
  still carries the Destroy policy (the Destroy override ordering after the
  profile's `rds_deletion_protection=true`), and that a partially installed
  target -- substrate present, platform never fully installed -- is still
  destructible (invariant 6); and
- `cli/test/check_production_infra.sh` asserts the steady-state cluster-access identity
  RBAC still grants no `escalate`/`bind`, preserving invariant 2 structurally.

## Consequences

- Two previously implicit rules become one explicit contract, so findings 13, 14
  and 15 share a single answer instead of three local patches.
- `sol cloud apply` installs the platform under the temporary privileged
  authority and de-escalates only after verified readiness; `sol cloud destroy`
  runs the destroy desired-state policy from a verified `PreparingDestroy`.
- BUG-039 is unchanged: production RDS stays protected throughout `Ready`. The
  destroy path deliberately leaves that policy domain rather than weakening it.
- No new identity, no phase-pointer file and no state database are added.

## Alternatives rejected

- **Grant the steady-state cluster-access identity `escalate`/`bind`:** `create` cannot be
  scoped by `resourceNames`, so this is an un-scopable escape that would let the
  steady-state cluster-access identity bind `cluster-admin` to itself — contradicting the
  enforceable negative boundary in ADR 0002.
- **Fix each finding by reordering `-var`s:** leaves the lifecycle's state
  transitions contradicting one another and produced findings 14 and 15 in
  sequence.
- **Persist a phase marker:** duplicates reality and can lie after partial
  failure; ADR 0002 already rejected a Sol phase pointer.
- **A generic state-machine framework:** the phases the lifecycle actually has
  are few and explicit; a framework would add surface without evidence.

## Related

- ADR 0002 — Sol owns the complete cloud-target lifecycle
- BUG-039 — production RDS deletion protection
- INFRA-022, INFRA-023 — implementation tickets
- HARDEN-002 runs 3–4, findings 13, 14 and 15
