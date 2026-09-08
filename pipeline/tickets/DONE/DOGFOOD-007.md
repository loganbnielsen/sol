---
id: DOGFOOD-007
type: feature
severity: blocker
source: dogfood/2026-06-11_DOGFOOD-001_fresh_install.md
---

Publish first release binary so the documented `curl` install path works.

**Depends on:** None.

**Problem:** The GitHub Actions release workflow (`release.yml`) is in place but no tag has been pushed to trigger it. The install URL `https://github.com/loganbnielsen/sun/releases/latest/download/sun-linux-x86_64` returns 404. The README's one-liner install is non-functional for any new user.

**Goal:** Produce at least one published binary so the fresh-install path is testable end-to-end.

**Remediation:**

1. Push a pre-release tag to trigger the workflow:
   ```bash
   git tag v0.1.0-alpha.1
   git push origin v0.1.0-alpha.1
   ```
2. Confirm the GitHub Actions workflow completes and `sun-linux-x86_64` appears in the release assets.
3. Verify the `curl` install one-liner in README returns 200 and produces a working binary.

**Acceptance criteria:**

- `curl -sSL .../sun-linux-x86_64` downloads a functional binary.
- Running the downloaded binary with `sun --version` prints `dev` or a version string.
- The workflow is documented as the release process in `docs/planning/WORK_SUMMARY.md`.
