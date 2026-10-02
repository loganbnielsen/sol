---
id: FEAT-109
type: feature
severity: medium
title: Add `sol ci init github` so an existing workspace gets a supported CI workflow with short-lived identity
source: DEC-057 and docs/DEVELOPER_EXPERIENCE.md §8 (2026-09-29)
---

**Depends on:** DEC-061.

**Related:** `DEC-057` (the contract), `DEC-016` (target selection is explicit; CI
must not infer one), `FEAT-012` (the scaffolded `.github/workflows/sol-ci.yml`
this generalises), `FEAT-053` (build-time secrets are declared by name, never
held), `RELEASE-005` (publishing the framework the CI build consumes),
`DEC-019` (a hosted service is not required for CI deployment).

## What this is

`DEC-057` §5 requires that continuous deployment not depend on a Sol-hosted
service: the user's existing CI system is a first-class execution environment.
Today `sol new workspace` writes a `.github/workflows/sol-ci.yml` for a *new*
workspace, but an existing workspace has no supported way to get that workflow,
and the generated workflow does not yet carry a provider-native short-lived
identity story.

## Required behaviour

- **Generate into an existing workspace.** `sol ci init github` (or an
  equivalent, decided in implementation) creates a supported workflow in a
  workspace that already exists, without overwriting unrelated files and without
  clobbering a workflow the user has edited.
- **Prefer short-lived/OIDC authentication** over long-lived cloud credentials,
  and make the required provider-side trust configuration explicit and
  discoverable.
- **Run the same lifecycle engine as local execution.** The workflow invokes
  `sol deploy <target>` and `sol migrate`; there is no separate CI deployment
  implementation and no CI-only manifest path.
- **Preserve the safety invariants.** Target selection stays explicit and fails
  closed; the workflow does not invent a destination from the branch or the
  environment (`DEC-016`). A production deploy requires the production identity,
  and access separation is not weakened for convenience.
- **Keep output diagnosable.** CI output and retained artifacts are as useful for
  diagnosis as local output, including the run id and the failure tail the local
  path already produces.
- **Support merge-to-main → deploy** as a documented, straightforward workflow.

## Remediation

- Generalise the existing scaffolded workflow template into a generator that can
  be applied to a workspace, sharing the template with `sol new workspace`.
- Decide and document the provider-native identity mechanism (OIDC trust or its
  provider equivalent), and make the workflow's failure mode explain a missing or
  mistrusted identity clearly. This is why the ticket depends on `DEC-061`: its
  destination/identity contract (declaration decides where, execution identity
  decides whether, ambient config decides neither) is the input the trust
  configuration must match. Do not reproduce a human kubeconfig setup flow.
- Ensure the generated workflow and the docs (DOCS-026/DOCS-028) agree, and that
  a reader can tell which secrets/OIDC subjects must be configured where.

## Non-goals

- Not a hosted CI product, and not a second deployment engine.
- Not a generic CI-vendor matrix — start with the supported provider(s) and add
  others deliberately.
- Not changing target addressing or adding a destination from branch names.
- Not holding secret values; the workflow declares what the CI system must supply
  (`FEAT-053`).

## Acceptance criteria

- `sol ci init github` produces a working, supported workflow in an existing
  workspace, and is safe to re-run.
- The workflow authenticates with a short-lived/OIDC identity by default, and the
  required provider-side trust is documented.
- The workflow deploys through the same `sol deploy <target>` lifecycle as local
  execution, with no CI-only path.
- Target selection remains explicit; the workflow cannot deploy to an inferred
  destination.
- A reader can follow the generated workflow plus the docs to set up CI without a
  Sol checkout or a private resource.

**Demo/example coverage:** add the CI path to the runnable documentation set (the
installation/deployment guides, DOCS-026/DOCS-028) and to `examples/pluto` so a
user can see the generated workflow and the identity configuration it expects.

**TypeScript parity:** No language-parity impact — the CI path is app-language
neutral; a TypeScript workspace uses the same generated workflow.

## Progress (2026-10-02, part A)

**Landed:** `sol ci init github` (`cmd_ci.ml` + `Sol_cli_ci`) writes
`.github/workflows/sol-ci.yml` into an existing workspace from a dedicated
template (`platform/shared/templates/ci/github/sol-ci.yml`), refusing to
overwrite a workflow the user has edited unless `--force`, and idempotent on a
re-run. The generated workflow authenticates with **GitHub OIDC**
(`id-token: write`, `aws-actions/configure-aws-credentials` role assumption,
GCP Workload Identity), reads `SOL_TARGET` from a repository variable and passes
it verbatim to `sol deploy` and `sol migrate` (no inference, DEC-016), and holds
no workload secret values. The command prints the repository variables and the
provider-side trust it expects. `examples/pluto` now carries the generated
workflow (its old kubeconfig `deploy.yml` is removed), §5 of
`docs/guides/deployment.md` documents the OIDC setup, and
`docs/reference/cli.md` is regenerated. Tests: `cli/test/inline/test_ci_init.ml`
(write, idempotent re-run, refuse-to-clobber, `--force`).

**Still open (ticket stays `READY_FOR_ENGINEERING`):** the gated authorization
job that assumes DEC-062's separately privileged reconciler is not in the
generated workflow yet, because the reconciler's CLI entry point is itself still
open (DEC-062's stage/plan integration); it lands with that command and the
`SOL_AUTHORIZATION_ROLE_ARN` trust it needs. Also open: unifying the scaffold's
own `templates/workspace/.github/workflows/` copy with this template so
`sol new workspace` writes the same OIDC workflow and the legacy `deploy.yml`
disappears everywhere.
