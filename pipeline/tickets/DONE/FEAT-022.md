---
id: FEAT-022
type: feature
severity: high
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: FEAT-022/self-contained-release-artifact
worktree: /home/lbendtly/Code/sun-FEAT-022-self-contained-release-artifact
---

Make the release artifact self-contained for workspace scaffolding.

**Depends on:** DOGFOOD-007.

**Problem:** The Linux release binary is live, but `sun new workspace` still
requires users to clone the Sun repo and set `SUN_HOME` so generated workspaces
can link framework source. That is acceptable for alpha dogfood, but it is not a
release-grade install experience.

**Goal:** A user who installs `sun` from a release can run `sun new workspace`
without understanding or cloning the framework repo layout.

**V1 decision:** Ship a release bundle, not a lone binary. The release artifact
should contain:

- `bin/sun`
- `share/sun/framework/`
- `share/sun/integrations/`
- any install metadata needed to resolve the bundle root

`SUN_HOME` remains a contributor escape hatch, but the downloaded release should
resolve its bundled source tree automatically. Do not switch generated
workspaces to opam packages in this ticket; the current vendor-link model stays
intact.

**Remediation:**

1. Update the release workflow to publish a versioned tarball containing the
   binary plus the framework/integration source tree.
2. Update `sun new workspace` source resolution so downloaded bundles work
   without manual `SUN_HOME`.
3. Preserve source-checkout behavior for contributors and worktrees.
4. Add an install smoke test that uses the release bundle in a clean temp
   directory.
5. Update README and tutorial to remove `SUN_HOME` from the primary path.

**Out of scope:**

- Replacing vendor links with opam package dependencies.
- Publishing to a package manager.
- macOS/arm64 release expansion.
- Removing `SUN_HOME`; it remains useful for source checkouts.

**Acceptance criteria:**

- Fresh install from GitHub Releases can run `sun new workspace acme` without a
  separate repo clone.
- Generated workspace builds with `dune build`.
- Existing source-checkout development flow still works.
- README quickstart has one primary install path.
