---
id: FEAT-090
type: feature
severity: medium
title: Extend the target-status surface with cloud health, drift and last operation
source: Sol Unified Operational Interface design review, 2026-09-18
---

**Depends on:** None.

**Related:** DEC-032, INFRA-027, OBS-044, ADR 0003.

## What this is

`sol target show --check` already reports a target's identity, Kubernetes
reachability, and platform readiness. It does not report what the review's
example output shows:

```text
Target: prod/aws/us-east-1
Platform: Ready
Cloud: Healthy               <- missing
Drift: None                  <- missing
Last operation: cloud apply  <- missing
```

Add those capabilities to the existing surface. The constraint that matters more
than the command name: **exactly one surface answers "what is the state of this
target"**. A second one is already in sight — the review proposes
`sol cloud status`, which would sit beside `sol target show` and re-derive the
same facts from the same sources. Whether `sol cloud status` becomes a thin alias
or is not added at all is an ergonomic implementation choice; a competing
target-state model is not.

Each new field has a real authority, and most of this ticket is naming it
honestly rather than computing something new:

- **Cloud health** — the provider's own view of the resources Sol manages, not a
  Sol-side record.
- **Drift** — the relationship between Terraform's recorded state and observed
  reality. A refresh/plan read only; never a mutation.
- **Last operation** — what Sol last did to this target, when, and with what
  outcome. There is no target-scoped record of this today, and ADR 0003 settles
  what may be added: the phase is *not* infrastructure truth, is recomputed each
  run, and "no phase-pointer file or second infrastructure state database is
  introduced". So this field must be derived from an existing authority — local
  run history (`.sol/runs/`), deployment events (`sol deployments`), or
  Terraform — or reported as unavailable. It must not persist a new
  target-scoped store.

The lifecycle *phase* itself is out of scope: ADR 0003 defines it, and
`Sol_cli_cloud_lifecycle` already carries `phase`, `phase_policy`,
`policy_of_phase`, `transition_allowed`, `ready_policy_applies` and
`policy_vars`. This ticket renders the phase; it does not define or re-derive it.
Note the ADR's rule when rendering it: readiness is *observed*, never inferred
from the phase — so the two must be reported as the distinct things they are
rather than reconciled into one word.

## Evidence (2026-09-18, `main` at 790dc3e8)

`sol target show --check` emits identity, reachability, and readiness only:

```text
cli/sol/bin/cmd_target.ml:67   let kubernetes_status ~check … -> Not_configured | Configured | Reachable | Unreachable
cli/sol/bin/cmd_target.ml:90   let platform_status ~check … -> readiness_summary (optional)
cli/sol/bin/cmd_target.ml:118  let show target verbose json check =
```

No drift read exists anywhere:

```text
$ rg -n 'drift' cli/ | wc -l
0
```

and there is no persisted cloud apply/destroy record, so "last operation" has no
authority to read from yet. `--check` is opt-in by design because the summary is
what an operator reads while diagnosing an unreachable cluster
(`cli/sol/bin/cmd_target.ml:1-6`), so no new probe may make the default
invocation block.

Two shape notes: `sol target show` requires a full `env/provider/region` path
(DEC-016 — no current target, no default), so the review's `--target prod`
shorthand is not valid today and is not part of this ticket. And `--json` already
exists, so any new field must appear there too.

## Non-goals

- Not a new target-state model, and not a second command that reports target
  state.
- Not drift *remediation*; reporting only. Applying is `sol cloud apply`.
- Not the lifecycle phase itself — ADR 0003 defines it.
- Not a new durable store for "last operation"; ADR 0003 rejects a phase pointer
  and a second infrastructure state database, and this field is no exception.
- Not infrastructure dashboards (INFRA-027).
- Not making any new read part of the default invocation; the offline summary
  stays offline.
- Not the `--target prod` shorthand (DEC-016 owns target addressing).

## Acceptance criteria

- `sol target show` reports cloud health, drift, and last operation alongside the
  existing identity/reachability/readiness fields, and `--json` carries the same
  fields.
- Each field names its authority in the code, and none is answered from a Sol
  record where the provider or Terraform state is authoritative.
- The offline invocation still returns without touching the network; the new
  reads sit behind the existing opt-in.
- Exactly one command family reports target state after this change. If
  `sol cloud status` is added, it delegates to the same projection and a test
  asserts the two agree.
- An unreachable or absent cloud reports as such, never as "healthy" by default.
- If last operation has no authority available, it reports as unavailable — not
  as "none" — so the absence of a record is not mistaken for a recorded absence.
- No new store, pointer file, or state database is introduced.

**Demo/example coverage:** `sol target show` is user-facing, so `examples/pluto`
(or `TUTORIAL.md`, whichever the run demonstrates against) must show the new
output, and `docs/deployment/production-bootstrap.md` must be updated if it
quotes the old shape.

**TypeScript parity:** No language-parity impact — target inspection is
language-neutral and no application-facing contract changes.
