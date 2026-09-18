---
id: INFRA-031
type: bug
severity: medium
title: Report every lifecycle phase ADR 0003 makes operator-visible
source: HARDEN-002 Run 5 attempt 1, 2026-09-18 — the qualification matrix claimed
  phases the CLI never printed
---

**Depends on:** None.

**Related:** ADR 0003 (phase is reported operational context), INFRA-029 (the
destroy entry), the qualification matrix rows I1/I3/I9, HARDEN-002 (the run that
found it).

## What happened

While executing Run 5 attempt 1 against a real AWS target, only some phases were
ever observable. `phase_to_string` had exactly three call sites in
`cli/sol/bin/cmd_cloud_tf.ml`:

- the refused-apply error message,
- the platform apply phase (`PlatformInstalling` / `PlatformUpdating`),
- the destroy phase (`PreparingDestroy` / `Absent`).

So **`CloudBootstrap`, `Ready` and `Destroying` never reached an operator.**
ADR 0003's own implementation note says the phase "is reported rather than only
acted on — it is what tells an operator which authority and desired-state policy
the run is applying", and attempt 1 showed why that matters: the phase lines were
among the most useful evidence the run produced, which is exactly what a phase
that exists only inside the model cannot supply.

The merged qualification matrix asserts all of these (rows I1, I3, I9). The fix
is therefore in the implementation, **not** a weakening of those rows.

## Remediation

Report each phase where the lifecycle actually enters it, and nowhere else:

- **`CloudBootstrap`** — before the privileged apply that creates the cloud
  substrate, and only on a positive observation that no substrate exists yet. A
  re-apply onto an existing substrate is not a bootstrap; there the platform
  stage reports the phase that run is actually in.
- **`Ready`** — only after readiness has been verified **and** the temporary
  privileged association has been revoked **and** the bounded provisioner has
  been re-verified effective. Reporting it at the transition *check* would claim
  a state the target has not been left in yet.
- **`Destroying`** — where the substrate teardown actually happens: preparation
  verified and the platform already gone. An absent target never enters it and
  reports `Absent` instead, so the claim is conditional.

### One behavioural refinement this forced

Deciding "does the substrate exist" before the apply means reading Terraform
outputs before the apply. The offline harness injects a failure per phase and
asserts the run fails closed, so it caught that a state read which *fails* was
being treated as "no substrate" — i.e. an unknown substrate was reported as
`Absent` and applied over. The read is now exhaustive: only `Ok None` (a
positively empty state) prints `CloudBootstrap`; `Error` fails the run.

## Acceptance criteria

- A target with no cloud substrate reports `CloudBootstrap` before the privileged
  apply, and a re-apply onto an existing substrate does **not**.
- A completed install reports `Ready`, and the phase is emitted only after
  readiness, de-escalation and provisioner verification have all succeeded.
- A destroy that tears down a substrate reports `Destroying`; a destroy of an
  absent target reports `Absent` and never `Destroying`.
- A failing state read fails the run rather than printing a phase or applying
  over an unknown substrate.
- The offline harness asserts all of the above, including that a re-apply is not
  misclassified and that each injected phase failure still fails closed.
- Matrix rows I1/I3/I9 remain as written.

**Demo/example coverage:** The destroy/apply phase lines now appear in the
tutorial's production-lifecycle walkthrough without further change; no example
edit is required beyond that.

**TypeScript parity:** No language-parity impact.
