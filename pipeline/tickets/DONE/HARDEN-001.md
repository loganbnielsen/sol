---
id: HARDEN-001
type: verification
severity: high
source: docs/audits/AUDIT.md
branch: HARDEN-001/post-alpha-security-reliability-audit
worktree: /home/lbendtly/Code/sun-HARDEN-001-post-alpha-security-reliability-audit
---

Run the post-alpha security and reliability audit.

**Depends on:** ALPHA-001, ALPHA-002, FEAT-024.

**Problem:** Once the public alpha path is credible, Sun needs a focused pass on
production safety. Dogfood verifies user flow; this ticket verifies that the
generated infrastructure and runtime defaults remain secure and reliable under
failure conditions.

**Goal:** Re-run the production-readiness audit against the post-alpha product
shape and convert findings into actionable tickets.

**Runbook:**

1. Copy `docs/audits/AUDIT.md` to
   `project/audits/<YYYY-MM-DD>_post_alpha_audit.md`.
2. Use a fresh generated workspace from the release bundle.
3. Run the executable audit sections for:
   - zero-to-running local loop
   - failure atomicity
   - observability smoke test
   - generated manifest security scan
   - rolling deploy behavior
   - migration failure handling
   - secret backend/GitOps output safety
4. Verify these invariants explicitly:
   - no non-empty secret values in emitted GitOps YAML
   - containers run as non-root with read-only root filesystems
   - seccomp profile is set
   - Services are ClusterIP, not NodePort
   - NetworkPolicy is emitted for every workload
   - rollback commands use the documented path format
   - fixed-tag redeploy either restarts pods or documents why it does not
   - partial deployment failures return non-zero and do not leave orphaned
     resources where Sun claims atomicity
5. Create one ticket per high/medium finding.

**Acceptance criteria:**

- Audit report is committed under `project/audits/`.
- Every high/medium finding has a ticket in `BACKLOG` or
  `READY_FOR_ENGINEERING`.
- Any failed security invariant blocks public-alpha promotion until fixed or
  explicitly accepted in the roadmap.

