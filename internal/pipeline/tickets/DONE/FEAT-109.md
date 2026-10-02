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

## Progress (2026-10-02, parts B and C)

**Premise verified:** part A's "still open" was accurate. `sol grants` now exists
(FEAT-127), so the authorization job can land; and the scaffold still carried its own
workflow copy plus `deploy.yml`.

**Part B — the gated authorization job.** The canonical workflow gains an `authorize`
job between `build-images` and `deploy`:

- it runs under the `sol-authorization` GitHub environment, so a required-reviewer
  protection makes adopting, dropping or widening a workload cloud grant an approved
  action separate from a merge (`DEC-062` rule 1);
- it assumes the target's **reconciler** identity, not the deploy identity, through
  `SOL_AUTHORIZATION_ROLE_ARN` (AWS OIDC) or `SOL_AUTHORIZATION_SERVICE_ACCOUNT` (GCP
  Workload Identity);
- it runs `sol grants plan "$SOL_TARGET"` then `sol grants apply "$SOL_TARGET"`;
- `deploy` now `needs: authorize`, so a declared grant is established before the deploy
  that consumes it. The authorization steps are skipped when neither variable is set, so
  a workspace that has not adopted cloud grants still deploys — and `sol deploy` still
  fails closed if a grant is not effective (FEAT-128).

**Part C — one canonical template.** The workflow now lives only at
`platform/shared/templates/workspace/.github/workflows/sol-ci.yml`;
`platform/shared/templates/ci/github/sol-ci.yml` and the scaffold's legacy
`deploy.yml` are deleted, and `Sol_cli_ci` reads the workspace template, so
`sol new workspace` and `sol ci init github` render the same file. The two duplicate
`platform/cloud/delivery/ci/*.yml` samples are also removed: the direct-deploy one was
the legacy kubeconfig/access-key `deploy.yml` the OIDC workflow replaces, and the GitOps
one was a second copy of the deploy lifecycle with long-lived credentials. GitOps mode
stays supported through `sol deploy --emit-to` plus the Argo CD `Application` in
`platform/cloud/delivery/argocd/`. `examples/pluto` carries the new workflow, and the
scaffold test asserts the scaffolded file *is* the canonical template rendered.

**Docs.** New [`docs/deployment/ci.md`](../../../docs/deployment/ci.md) is the single CI
reference: jobs, the two identities, OIDC subjects, repository variables, the two
protected environments and the one secret. `docs/guides/deployment.md`,
`docs/guides/TUTORIAL.md`, `docs/architecture/devops-pipeline.md` and
`docs/reference/substrate.md` are updated to it, and `sol ci init`'s printed next steps
name the authorization variables and the environment gate.

**Tests.** `test_ci_init.ml` asserts the gated authorization job and `needs: authorize` in
the generated workflow; `test_scaffold.ml` asserts there is no `deploy.yml`, that the
authorization job is gated and runs `grants`, that authentication is OIDC with no
kubeconfig, and that the scaffold renders the canonical template. Build, format and the
full fast-check set pass. No language-parity impact (`DEC-022`): the CI path is
app-language neutral.

