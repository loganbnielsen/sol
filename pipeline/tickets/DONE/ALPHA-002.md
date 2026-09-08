---
id: ALPHA-002
type: verification
severity: high
source: docs/audits/DOCS_AUDIT.md
branch: ALPHA-002/public-alpha-docs-readiness
worktree: /home/lbendtly/Code/sun-ALPHA-002-public-alpha-docs-readiness
---

Run the public alpha documentation and release readiness audit.

**Depends on:** ALPHA-001.

**Problem:** After the release-user dogfood passes, the docs and generated
workspace instructions must match the product exactly. A public alpha user
should not need contributor knowledge, stale roadmap context, or raw Kubernetes
commands for the normal path.

**Goal:** Verify and reconcile the public-facing docs against the actual release
artifact and generated workspace.

**Runbook:**

1. Start from the same release bundle and workspace used in `ALPHA-001`.
2. Audit these documents against implementation and command output:
   - `README.md`
   - `docs/guides/TUTORIAL.md`
   - generated workspace `README.md`
   - `docs/deployment/self-hosted-substrate-contract.md`
   - `docs/deployment/escape-hatches.md`
   - `docs/planning/ROADMAP.md`
3. Verify every documented command exists:

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

4. Follow the README quickstart exactly as written in a clean directory.
5. Follow the tutorial's local path exactly as written.
6. Record each mismatch as a finding using the format from
   `docs/audits/DOCS_AUDIT.md`.
7. Patch docs or generated README templates for every high/medium finding found
   during the audit.

**Acceptance criteria:**

- README and tutorial quickstarts work from the release bundle.
- Docs no longer require `SUN_HOME` or a source checkout in the primary path.
- GitOps docs describe External Secrets backend refs and do not warn that Sun's
  default GitOps output contains plain-text secrets.
- Every command/flag shown in docs exists in CLI help.
- Generated workspace README matches generated file layout and commands.
- All high/medium doc findings are fixed or converted into follow-up tickets.

