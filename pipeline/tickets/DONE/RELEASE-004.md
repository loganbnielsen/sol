---
id: RELEASE-004
type: release
severity: high
source: release-run-27380645597
branch: RELEASE-004/release-action-hotfix
worktree: /home/lbendtly/Code/sun-RELEASE-004-release-action-hotfix
---

Fix the release action pin and publish the next alpha.

**Depends on:** RELEASE-001.

**Problem:** The `v0.1.0-alpha.5` release workflow failed during job setup
because `softprops/action-gh-release@v5` does not exist. The tag is already
pushed, so the next clean publication should use a new alpha tag instead of
rewriting the failed public tag.

**Goal:** Publish `v0.1.0-alpha.6` with the same post-hardening code and a valid
GitHub release action pin.

**Remediation:**

1. Change `.github/workflows/release.yml` from
   `softprops/action-gh-release@v5` to the latest valid major,
   `softprops/action-gh-release@v3`.
2. Keep `actions/checkout@v5`, which is a valid current major.
3. Run local release preflight:

   ```bash
   eval $(opam env) && dune build
   eval $(opam env) && dune build cli/sun/bin/main.exe
   eval $(opam env) && dune test cli/sun/test
   ./platform/local/scripts/run_tests.sh unit --no-infra
   ```

4. Push `main`, tag `v0.1.0-alpha.6`, and push the tag.
5. Confirm the GitHub release job completes and publishes both release assets.

**Acceptance criteria:**

- The release workflow no longer references nonexistent action versions.
- The release workflow completes successfully for `v0.1.0-alpha.6`.
- The release contains `sun-linux-x86_64`.
- The release contains `sun-v0.1.0-alpha.6-linux-x86_64.tar.gz`.
- `RELEASE-002` points its clean smoke test at `v0.1.0-alpha.6`.

## Review — automated checks passed
Verified dune build passes, release workflow pin changes softprops/action-gh-release from @v5 to @v3, checkout remains @v5, diff is limited to release.yml plus perf history, and project/tickets is untouched.
