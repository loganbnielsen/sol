---
id: DOGFOOD-001
type: feature
severity: blocker
source: product-planning-2026-06-11
branch: DOGFOOD-001/fresh-install-workspace
worktree: /home/lbendtly/Code/sun-DOGFOOD-001-fresh-install-workspace
---

Fresh install and workspace creation dogfood.

**Depends on:** EXP-001.

**Problem:** Sun's first-run path has not been proven from the GitHub release
install path. The binary install requires `SUN_HOME`, runtime libraries, and a
source checkout for generated workspace vendor links; this may be too confusing
for a new user.

**Goal:** Prove and document the cleanest fresh-install path from an empty
environment to a generated workspace that builds.

**Remediation:**

1. Start from a clean shell/environment with no `_build` symlink install.
2. Install `sun` from the GitHub Releases binary URL.
3. Clone or point at the Sun source checkout and set `SUN_HOME`.
4. Run `sun new workspace dogfood_acme`.
5. Run `dune build` inside the generated workspace.
6. Record every missing prerequisite, confusing message, or broken symlink.
7. Convert findings into focused follow-up tickets or fixes.

**Acceptance criteria:**

- A generated workspace builds from the release-installed `sun` binary.
- README and tutorial instructions match the tested path.
- Any remaining manual setup is explicit and justified.
