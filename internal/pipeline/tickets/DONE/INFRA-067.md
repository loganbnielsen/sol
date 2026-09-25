---
id: INFRA-067
type: bug
severity: high
title: A target Sol accepts for creation must retain a destruction path
source: FND-0029 — GCP Attempt 5 (2026-09-22)
---

**Depends on:** None.
**Related:** `FND-0029` (the evidence), `FND-0007` (the refusal's wording and the
missing Cloud DNS solver), `FND-0028` / `DEC-043` (durable prerequisites and which
stage owns them), `docs/qualification/2026-09-22-gcp-attempt5.md`.

## The invariant to establish

> **Any target Sol permits to create billable infrastructure must retain a supported
> destruction path without requiring undocumented configuration surgery.**

## What happened

A GCP target declaring `cluster_issuer: letsencrypt-staging` was accepted by
`sol cloud apply --apply` (14 resources created) and refused by
`sol cloud destroy --apply` in the `PreparingDestroy` phase, with the
`cluster_issuer`/Cloud-DNS-solver refusal. `sol cloud destroy --plan` accepts the same
target, so the fault is in the mutating destruction path, not target parsing. The
teardown only proceeded after `cluster_issuer` was removed from the untracked target,
which is the correction the refusal's own text prescribes.

## Why this is high severity

The refusal is correct in intent — Sol should not pretend it can wire a certificate
issuer on GCP today — but it is evaluated at a moment where it has no remediation
available and where it blocks the one supported way to stop spending money. A safety
check that strands billable infrastructure is worse than the failure it guards
against, and here it required an operator who could read the error and know that
editing the declaration was safe.

## Remediation

The requirement is the invariant; the mechanism is deliberately not prescribed here,
because the evidence supports more than one repair:

- **Do not run install-time validation in `PreparingDestroy`,** or evaluate it in a
  form that a destruction-only phase can satisfy — the platform is not being installed
  during a destroy, so a guarantee about the platform's issuer is not actionable there.
- **Or refuse the configuration at creation.** If Sol cannot install what the
  declaration asks for, and that inability also makes the target unsafe to destroy,
  then the declaration should not be accepted in the first place. This is the weaker
  option only in the sense that it spends nothing but also builds nothing: it does not
  by itself restore a destruction path for targets already in that state.

Whichever is chosen, install-time validation must not be weakened, and a target that
has *already* been created in the refused shape must still be destroyable.

## Acceptance criteria

- `sol cloud destroy --apply` succeeds on a target that `sol cloud apply --apply`
  accepted, with no edit to the target declaration between the two commands.
- A regression test fails if the `PreparingDestroy` path can be refused by a
  validation that creation accepts. Prefer a test that does not require billable
  resources (the refusal is reachable before any resource is destroyed, so a state
  fixture or an offline harness is sufficient).
- The class is checked, not just the instance: any other install-only validation
  reachable from the destruction path is either made destroy-safe or explicitly
  recorded as out of scope.
- Install-time validation is demonstrated unchanged.

## Localization (2026-09-23)

The refusal is not in the target parser and not in the destroy policy variables
(`policy_vars` carries only provider facts). It is a **guard inside the platform
definition's variable computation**:

- `Sol_cli_cloud_lifecycle.platform_terraform_vars`, GCP branch
  (`cli/sol/lib/sol_cli_cloud_lifecycle.ml:363-372`):
  `match inputs.cluster_issuer with Some _ -> Error "…" | None -> Ok …`. The guard
  exists so Sol cannot provision a platform that looks TLS-wired and cannot issue —
  and it produces no variable the non-refusing branch would not also produce, so it is
  a guard rather than a branch.
- Its callers: `cli/sol/bin/cmd_cloud_tf.ml:739-744` (`platform_inputs` →
  `platform_terraform_vars`), used by **every platform phase, including
  `platform-destroy`** (`cmd_cloud_tf.ml:2669`).
- The destroy sequence is: lower the cloud guards → reconciliation apply → **the
  platform-destroy step**, where the platform's variables are computed and the guard
  fires.
- **Both branches reach it.** `cloud_destroy` computes the platform's variables in its
  `Plan` branch as well as its mutating one (`cmd_cloud_tf.ml:2658, 2758`), so the guard
  is reachable from either. An earlier revision of this section claimed `destroy --plan`
  "never reaches" it and that this explained a plan/apply disagreement; that was wrong —
  the recorded plan run passed because the substrate was already absent, so the platform
  step was deferred and the variables were never computed. *Corrected 2026-09-23.*

So the fix is a **context distinction, not a field exception**: the guard encodes a
capability requirement for *installing* the platform, and a destruction must not
evaluate it. A `?context` (`` `Install `` / `` `Destroy ``) on
`platform_terraform_vars`, passed as `` `Destroy `` from the platform-destroy path,
gives `destroy --apply` the same destruction-relevant contract as `destroy --plan`
while install/apply keeps the refusal. `cli/sol/test/test_cloud_lifecycle.ml:260-263`
already asserts the install-side refusal and is the natural home for the destroy-side
acceptance test.

## Fix (2026-09-23)

`Sol_cli_cloud_lifecycle.platform_terraform_vars` takes `?context:Install | Destruction`,
defaulting to `Install` so no other caller's behaviour changes, and evaluates the GCP
issuer refusal only under `Install`. `platform_vars_of` threads the context through, and
`cloud_destroy`'s two call sites pass `Destruction`; `cloud_init`'s still passes the
default, so installation is exactly as strict as it was.

Regression: `test_platform_vars_destruction_context` asserts both directions together —
installation refuses a GCP target asking for TLS, destruction accepts it — so neither can
drift. Mutation-checked: with the context ignored (the pre-fix behaviour, written so it
still compiles) that single test fails and the rest pass; reverting restores 27/27.

**Not machine-verified, stated rather than implied:** that `cloud_destroy` *passes*
`Destruction` is a call-site fact. The executable that owns it is not linkable from the
test suite, and a live reproduction needs substrate — the very thing the defect made hard
to remove. So the wiring is reviewed, not tested. A path that could still reach the guard
with `Install` during destruction is a new instance of this defect, not a regression of
this fix.

## Out of scope

- The Cloud DNS solver itself (`FND-0007`), which is what makes the refusal correct
  today. This ticket is about *when* the refusal is evaluated.
- Which stage owns durable prerequisites (`DEC-043`).

## Completion notes (2026-09-25) — bookkeeping: the fix merged, the ticket did not move

**Problem.** `sol cloud destroy --apply` refused a target `sol cloud apply` had accepted: the
`cluster_issuer`/Cloud-DNS refusal was evaluated inside `PreparingDestroy`, where it has no
remediation and blocks the only supported way to stop spending (FND-0029, GCP Attempt 5).

**Root cause.** The guard is a *capability requirement for installing* the platform. The destruction
path computes the platform's variables in order to remove the platform, and re-evaluated an
install-time requirement there.

**Change.** `Sol_cli_cloud_lifecycle.platform_terraform_vars` takes
`?context:Install | Destruction`, defaulting to `Install` so installation is exactly as strict as it
was; the destroy-path call sites pass `Destruction`
(`cli/sol/bin/cmd_cloud_tf.ml:1278,1371`); the provider's own half is the guard in
`Sol_cli_gcp_cluster.platform_vars`, which refuses `Some _, Install` and accepts
`Some _, Destruction | None, _`. Merged as #445 (`4a9db5e5`), and the fix survived the
provider-boundary refactor (REFAC-095/096), which is where the branch moved into the provider
module.

**Why this commit is bookkeeping only.** #445 landed the code and updated this ticket but never
moved it out of `READY_FOR_ENGINEERING` (it predates the transition guard). What remained was read
out of the current code and the record, not implemented here:

- **AC1** (`destroy --apply` succeeds on a target `apply` accepted, with no edit in between) is a
  *live* observation. It belongs to the GCP qualification run — HARDEN-006 / Attempt 8 performs
  exactly that sequence (a target whose platform install stopped at cert-manager, then the
  documented destroy) — and FND-0029 carries `FIXED_UNQUALIFIED` until it happens.
- **AC2** landed as `cli/sol/test/test_cloud_lifecycle.ml`'s `test_platform_vars_destruction_context`
  (line 417), which asserts both directions in one test and was mutation-checked.
- **AC3** (the class is checked, not just the instance): the context has exactly one consumer —
  `rg -n 'platform_vars_context' cli/sol` finds `Sol_cli_gcp_cluster.platform_vars` (this refusal)
  and `Sol_cli_cloud_lifecycle`'s re-export; the AWS provider deliberately ignores it
  (`sol_cli_aws_cluster.ml:833`, `platform_vars outputs _context ~cluster_issuer:_ ~region`). So no
  other install-only validation is reachable from the destruction path today.
- **AC4** (install-time validation unchanged): the same test asserts the install-side refusal.

**Demo/example: not applicable** — an internal lifecycle asymmetry; nothing an application author
writes changes. **Language parity (DEC-022): no application-facing impact.**
