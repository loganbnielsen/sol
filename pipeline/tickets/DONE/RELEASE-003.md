---
id: RELEASE-003
type: documentation
severity: medium
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: RELEASE-003/public-docs-reconciliation
worktree: /home/lbendtly/Code/sun-RELEASE-003-public-docs-reconciliation
---

Reconcile public docs after the post-hardening release smoke test.

**Depends on:** RELEASE-002.

**Problem:** README and tutorial claims need to match the artifact that users
actually download. The dogfood sweep fixed many product gaps, but any mismatch
found during the clean release smoke test should be patched before calling the
alpha path stable.

**Goal:** Make the public docs and generated workspace README match the
`v0.1.0-alpha.6` release-user path exactly.

**Remediation:**

1. Review the transcript produced by `RELEASE-002`.
2. Audit and patch:
   - `README.md`
   - `docs/guides/TUTORIAL.md`
   - generated workspace README templates
   - `docs/deployment/self-hosted-substrate-contract.md`
   - `docs/deployment/escape-hatches.md`
   - `docs/planning/ROADMAP.md`
3. Verify every documented command and flag against CLI help:

   ```bash
   sun --help
   sun new --help
   sun dev --help
   sun up --help
   sun deploy --help
   sun status --help
   sun logs --help
   sun migrate --help
   sun rollback --help
   ```

4. Convert any unfixed high or medium mismatch into a new ticket.

**Acceptance criteria:**

- README quickstart works from the published tarball.
- Tutorial local path works from the published tarball.
- Docs do not require `SUN_HOME` or a source checkout for the primary path.
- GitOps docs describe External Secrets backend references accurately.
- Generated workspace README matches generated file layout and commands.
- No known high or medium docs mismatch remains undocumented.
