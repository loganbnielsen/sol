---
id: FEAT-013
type: feature
severity: low
source: ROADMAP.md
branch: FEAT-013/docs-roadmap-reality
worktree: ../sun-FEAT-013-docs-roadmap-reality
---

Align roadmap and docs with current implementation reality.

**Problem:** Several roadmap statements still describe `Sun_cli.Toml`, `[infra.env]`, and the deployment pipeline as future work, while the implementation now includes typed deployment plans, environment targets, executors, deployment plan JSON, and basic `sun.toml` parsing.

**Goal:** Make README, ROADMAP, and product docs accurately reflect what is implemented, what is partial, and what remains future-facing.

**Remediation:**

1. Update the Phase 6 status table.
2. Distinguish implemented `sun.toml` fields from proposed future fields.
3. Mark Argo Rollouts and hosted executor work as future.
4. Ensure README, ROADMAP, and `docs/escape-hatches.md` use the same terminology.
5. Remove or rewrite stale "next" claims that are already complete.

**Out of scope:**

- New implementation work.
- Rewriting the product vision.
- Freezing the deployment plan JSON schema.

**Acceptance criteria:**

- Docs no longer claim completed work is pending.
- Docs no longer imply unsupported fields are available.
- The next-step backlog points to the relevant ticket IDs.
- A reader can tell the difference between local, customer-cloud, GitOps, and future hosted paths.

## Review — automated checks passed
FEAT-013: All acceptance criteria met. ROADMAP.md Phase 6 marked complete with full deliverable list; Phase 7 section added covering FEAT-010/011/012 with ticket IDs. README.md status markers corrected (HTTP/observability/deployment all done), sun.toml section updated with correct field names, Deployment Modes section added covering local/direct/GitOps/plan-emit paths, Project Structure updated. WORK_SUMMARY.md stale Next Up list replaced with Current State table (all Phase 6 items done) and Open Work table (FEAT-010..013). escape-hatches.md verified — terminology consistent, no changes required. No code changes; dune build clean; all 5 pre-commit suites pass.
