---
id: FEAT-024
type: feature
severity: medium
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: FEAT-024/deployment-plan-v2-contract
worktree: /home/lbendtly/Code/sun-FEAT-024-deployment-plan-v2-contract
---

Expand the deployment plan into a release-review contract.

**Depends on:** FEAT-021, ALPHA-001.

**Problem:** `FEAT-021` makes deployment plans include static topics and
migration files. That is enough to fix the dogfood gap, but a production release
review also needs to show runtime impact: schema subjects, consumer groups,
secret backend mode, rollout strategy, ingress/domain exposure, and eventually
pending/applied migration status.

**Goal:** Turn `--emit-plan-to` into the shared release-review contract used by
customer-cloud deploys, exported GitOps, hosted release inspection, and future
UI/API surfaces.

**V1 scope:**

- Add schema subject names derived from event contracts.
- Add consumer group names derived from worker identity.
- Add secret backend mode from the deployment target.
- Add rollout strategy/progressive delivery summaries.
- Add ingress/domain exposure summaries.
- Keep pending/applied migration state as follow-up unless database access is
  already available through the deployment target without new secrets.

**Verification commands:**

```bash
sun deploy --dry-run --emit-plan-to /tmp/sun-plan-v2.json
cat /tmp/sun-plan-v2.json | python3 -m json.tool
```

Inspect the JSON for:

- `topics`
- `migrations`
- `schema_subjects`
- `consumer_groups`
- `secret_backend`
- `rollout`
- `ingress`

**Acceptance criteria:**

- Plan JSON is deterministic and contains no secret values.
- Hosted release inspection can consume the new fields without a parallel model.
- Human-readable `pp_summary` shows release-impact sections without becoming
  noisy for small workspaces.
- Tests cover serialization, determinism, and secret-value absence.

