---
id: FEAT-015
type: feature
severity: medium
source: DEC-007
branch: FEAT-015/release-inspection-diagnostics
worktree: ../sun-FEAT-015-release-inspection-diagnostics
---

Add hosted release inspection and diagnostics.

**Depends on:** DEC-007, FEAT-010.

**Problem:** Sun-hosted users should not need to understand Argo CD, GitOps repos,
or Kubernetes internals to deploy, but they still need enough visibility to trust
the system and debug failures.

**Goal:** Provide a Sun-native release inspection surface with a read-only
diagnostic escape hatch for deeper details.

**Remediation:**

1. Define a release inspection model:
   - release id
   - environment
   - submitted deployment plan summary
   - image refs
   - services affected
   - rollout status
   - health status
   - error/failure reason
2. Add a detailed diagnostics view that can expose:
   - rendered manifests
   - reconciliation events
   - rollout resource names
   - Kubernetes event summaries
   - raw failure details
3. Keep diagnostics read-only.
4. Avoid requiring users to know or operate Argo/Kubernetes for the default flow.
5. Add docs explaining the default release view and advanced diagnostics.

**Out of scope:**

- Direct Argo CD access for hosted users.
- Direct Kubernetes write access for hosted users.
- Building a full web UI.
- Long-term release analytics.

**Acceptance criteria:**

- Hosted release responses have enough structure for inspection.
- Users can see what changed, what is rolling out, and why a release failed.
- Advanced diagnostics expose facts without exposing hosted control-plane
  ownership.
- Customer-cloud users can still inspect emitted manifests through GitOps paths.

## Review — automated checks passed
FEAT-015 review passed: release inspection and diagnostics model is read-only, hosted mock response includes inspection payload, rendered manifests are split into individual resource facts, docs and tests cover acceptance criteria.
