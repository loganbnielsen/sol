---
id: AUDIT-028
type: audit-finding
severity: medium
source: project/audits/2026-06-11_audit.md
branch: AUDIT-028/consumer-group-change-detection
worktree: ../sun-AUDIT-028-consumer-group-change-detection
---

Consumer group ID changes not detected before deploy

**Depends on:** None.

**Description:** The deployment plan records `consumer_groups` (derived from workspace structure) but does not compare against the currently deployed group IDs (`cli/sun/lib/sun_cli_deployment_plan.ml` lines 207, 328). A typo or intentional rename of `group_id` in a worker causes the new group to start consuming from the latest offset on first deploy, silently skipping any messages produced during the switchover.

**Impact:** Silent message loss or double-processing on consumer group ID renames. No warning is emitted before or after deploy.

**Remediation:** Store the last deployed `consumer_groups` in a ConfigMap (`sun-deploy-state`) per workspace namespace. On each deploy, compare the incoming plan's groups against the stored set. Emit a prominent warning (and require `--confirm-group-change` to proceed) if any group ID is renamed or removed.

## Review — automated checks passed
All checklist items satisfied; build clean; no shell injection; JSON escaping advisory fixed in follow-up commit (String.escaped applied to ConfigMap name field).
