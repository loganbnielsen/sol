---
id: FEAT-012
type: feature
severity: medium
source: ROADMAP.md
branch: FEAT-012/ci-workflow-scaffold
worktree: ../sun-FEAT-012-ci-workflow-scaffold
---

Scaffold CI workflow files in new Sun workspaces.

**Depends on:** FEAT-008.

**Problem:** Sun supports `sun deploy`, GitOps emit mode, and deployment plan export, but `sun new workspace` does not yet generate a CI workflow that shows the intended build/test/deploy path. A new team still has to assemble the pipeline manually.

**Goal:** Generate a conservative GitHub Actions workflow that tests the workspace, builds service images, exports a deployment plan, and optionally deploys or emits manifests.

**Remediation:**

1. Add a `.github/workflows/sun-ci.yml` template to the workspace scaffold.
2. Run `dune build` and `dune runtest`.
3. Build and push service images using the existing service discovery conventions.
4. Run `sun deploy --image-tag <sha> --emit-plan-to ...`.
5. Support GitOps emit as the default deploy-safe path.
6. Document required secrets and registry variables.
7. Add scaffold tests that assert the workflow exists and contains the expected Sun commands.

**Out of scope:**

- Provider-specific cloud provisioning.
- Hosted Sun deploy submission.
- Supporting every CI provider in the first pass.
- Publishing official binaries.

**Acceptance criteria:**

- `sun new workspace <name>` creates a workflow file.
- The workflow reflects current `sun up` versus `sun deploy` semantics.
- The generated file does not require Kubernetes credentials for the test/build steps.
- Registry and deploy credentials are explicit placeholders.
- Existing scaffold tests remain green.

**Implementation note:**

- Added `.github/workflows/sun-ci.yml` to the generated workspace scaffold. The workflow runs `dune build` and `dune runtest` without cluster credentials, skips image publishing on pull requests, rebuilds service binaries before Docker image creation, pushes service images with explicit registry secrets, exports a deployment plan, and emits GitOps manifests without requiring `KUBECONFIG`.
- Moved the `sun new` command implementation into the `sun_cli` library so scaffold behavior can be covered by Dune tests, while keeping the public CLI command unchanged.
- Added scaffold tests that assert the CI workflow is generated and contains the expected `sun deploy`, `--emit-plan-to`, `--emit-to`, Dune, registry secret, and no-`KUBECONFIG_B64` behavior.

## Review — returned for revision
- `hygiene/tickets/REVIEW/FEAT-012.md:1` — hygiene/tickets/ must only be modified in the main checkout, never inside a worktree branch (CLAUDE.md policy). The diff renames hygiene/tickets/BACKLOG/FEAT-012.md to hygiene/tickets/REVIEW/FEAT-012.md inside the feature branch.
- `README.md:232` — Acceptance criterion F requires at least one user-facing doc to mention CI workflow generation. The scaffold table ('What the scaffold generates') does not include .github/workflows/sun-ci.yml or .github/workflows/deploy.yml. Neither README.md nor WORK_SUMMARY.md have any diff in this branch.

## Review — returned for revision
- `hygiene/tickets/BACKLOG/FEAT-012.md:0` — hygiene/tickets/ path appears in branch diff (as deletion). The original implementation commit 2ecdf45 added this file to the worktree branch; the fix commit d369674 removed hygiene/tickets/REVIEW/FEAT-012.md but did not remove the BACKLOG deletion from the branch diff. The net diff of FEAT-012/ci-workflow-scaffold vs main still shows a hygiene/tickets/ mutation. Tickets must only be modified in the main checkout, never inside a worktree branch.

## Review — automated checks passed
FEAT-012 CI workflow scaffold passes all checks: clean build, zero hygiene/tickets/ delta, all 9 scaffold tests green, sun-ci.yml generated with correct jobs, no KUBECONFIG in build/test job, registry creds as secret placeholders, --emit-plan-to and --emit-to present, README scaffold table updated, (wrapped false) convention respected.
