---
id: FRIC-020
type: dogfood-finding
severity: medium
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Runbook and dogfood skill tell users to run `sol status` for the local cluster, but it errors

**Description:** `docs/dogfood/DOGFOOD.md` step 6 and `.claude/skills/dogfood/SKILL.md` step 6 both say `sol status`. Running it on the local cluster errors:

```
error: `sol status` needs --target <env>/<provider>/<region> to know which cluster to reach;
       for Sol's own local cluster use `sol local status`
```

The scaffold's printed next-steps (`cli/sol/lib/sol_cli_cmd_new.ml:164`) also say `sol status`. The error message itself is correct and helpful — the documentation is what's stale, and `sol local status` works and reports domain + observability health.

**Impact:** The final "is it running?" step of the documented golden path fails on a copy-paste. Recoverable because sol's error names the right command, but it makes the runbook look unmaintained at exactly the moment a user is checking success.

**Remediation:** Update `DOGFOOD.md`, `.claude/skills/dogfood/SKILL.md`, and the scaffold next-steps to `sol local status`.

Related: FRIC-015 (same next-steps block names removed `sol dev` commands).
