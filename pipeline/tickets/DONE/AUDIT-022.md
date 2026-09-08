---
id: AUDIT-022
type: audit-finding
severity: low
source: project/audits/2026-06-11_audit.md
branch: AUDIT-022/auto-forward-pg-polling
worktree: ../sun-AUDIT-022-auto-forward-pg-polling
---

`auto_forward_pg` uses ambient `Unix.sleepf 2.0` timing

**Depends on:** None.

**Description:** When `POSTGRES_URL` is unset and a cluster postgres exists, `sun migrate` starts a background `kubectl port-forward` and unconditionally sleeps 2 seconds (`cli/sun/bin/cmd_migrate.ml` line 17). If the port-forward takes longer to establish on a cold or loaded cluster, the subsequent connection attempt fails with a misleading "connection refused" error.

**Impact:** Flaky `sun migrate` on cold clusters; misleading error output.

**Remediation:** Replace `Unix.sleepf 2.0` with a short polling loop that retries a TCP connect to `localhost:15432` up to ~10× at 0.5 s intervals before giving up.

## Review — automated checks passed
Unix.sleepf 2.0 replaced with a TCP-connect polling loop: up to 10 attempts at 0.5s intervals, warning on timeout, at_exit cleanup preserved.
