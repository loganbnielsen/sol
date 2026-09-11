---
id: FEAT-011
type: feature
severity: medium
source: ROADMAP.md
branch: FEAT-011/argo-rollouts
worktree: ../sun-FEAT-011-argo-rollouts
---

Add Argo Rollouts support for progressive delivery.

**Depends on:** FEAT-009.

**Problem:** Sun can currently render standard Kubernetes `Deployment` resources with secure defaults and limited `sun.toml` escape hatches. The roadmap promises canary and blue-green rollout support through a high-level `sun.toml` section, but the renderer does not yet synthesize Argo `Rollout` resources.

**Goal:** Allow services to opt into canary or blue-green rollout behavior without writing Argo manifests by hand.

**Remediation:**

1. Define the supported `sun.toml` shape for progressive delivery.
2. Parse and validate the rollout config.
3. Extend the deployment plan with progressive rollout intent.
4. Render Argo `Rollout` resources instead of `Deployment` when configured.
5. Keep standard `Deployment` as the default.
6. Add tests for default behavior, canary rendering, blue-green rendering, and invalid configs.
7. Update docs with supported fields and non-goals.

**Out of scope:**

- Arbitrary Argo Rollouts configuration.
- Traffic-manager integrations beyond the first supported strategy.
- Hosted release orchestration.
- Automated metric analysis unless explicitly chosen in a later ticket.

**Acceptance criteria:**

- A service with no rollout config still renders a normal `Deployment`.
- A service with canary config renders a valid Argo `Rollout`.
- A service with blue-green config renders a valid Argo `Rollout`.
- Invalid rollout configs fail before any cluster apply.
- Docs are clear that this is a typed high-level escape hatch, not raw Argo YAML.

## Review — returned for revision
- `hygiene/tickets/REVIEW/FEAT-011.md:1` — hygiene/tickets/ directory modified inside the worktree branch — ticket state changes must only happen in the main checkout, never in a feature branch

## Review — automated checks passed
FEAT-011 fully implements Argo Rollouts support: build clean, all 43 manifest tests pass, all 7 remediation items addressed, no hygiene/tickets/ violations in diff.
