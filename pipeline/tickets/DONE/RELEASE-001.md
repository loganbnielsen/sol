---
id: RELEASE-001
type: release
severity: high
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: RELEASE-001/post-hardening-alpha-release
worktree: /home/lbendtly/Code/sun-RELEASE-001-post-hardening-alpha-release
---

Prepare and publish the post-hardening alpha release.

**Depends on:** SEC-001, SEC-002.

**Problem:** The live `v0.1.0-alpha.4` release proves that the release workflow
can publish a Linux binary and self-contained bundle, but the security fixes and
post-alpha hardening are newer than that release. The next public alpha artifact
should include those fixes and remove the known GitHub Actions deprecation
warning before more release-user verification.

**Goal:** Publish `v0.1.0-alpha.5` with the standalone `sun-linux-x86_64`
binary and the self-contained `sun-v0.1.0-alpha.5-linux-x86_64.tar.gz` bundle.

**Remediation:**

1. Update `.github/workflows/release.yml` from deprecated action majors to the
   current majors already selected for this repo:
   - `actions/checkout@v5`
   - `softprops/action-gh-release@v5`
2. Run local release preflight from `main`:

   ```bash
   eval $(opam env) && dune build cli/sun/bin/main.exe
   eval $(opam env) && dune test cli/sun/test
   ./platform/local/scripts/run_tests.sh unit --no-infra
   ```

3. Verify the release workflow still stages:
   - `dist/sun-linux-x86_64`
   - `dist/sun-v0.1.0-alpha.5-linux-x86_64.tar.gz`
   - `framework/` and `integrations/` inside the tarball.
4. Push `main`, tag `v0.1.0-alpha.5`, and push the tag.
5. Confirm the GitHub release job completes and both release assets are present.

**Acceptance criteria:**

- Release workflow uses the non-deprecated action majors.
- Local release preflight passes.
- `v0.1.0-alpha.5` exists on GitHub as a prerelease or release.
- `sun-linux-x86_64` downloads and runs `sun --help`.
- The tarball contains `bin/sun`, `framework/`, and `integrations/`.

**Out of scope:**

- macOS or arm64 binaries.
- Installer checksum enforcement.
- Hosted product implementation.

## Review — returned for revision
- `dune-project:4` — `dune build` fails: package `sun` has no user-defined stanzas attached; Dune suggests adding `(allow_empty)` if intentional.

## Revision
- Add the minimal Dune package configuration needed for the repository-wide
  review build to pass.

## Review — automated checks passed
Verified eval opam env dune build passes, diff is scoped to release workflow/dune-project/perf samples, remediation/revision note are reflected, and project/tickets is untouched.
