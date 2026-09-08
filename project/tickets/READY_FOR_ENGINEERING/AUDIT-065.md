---
id: AUDIT-065
type: audit-finding
severity: medium
source: direct investigation, 2026-09-07 — root cause of the recurring "kubectl port-forward already bound to port 3100" false failure hit 3 times during this session's merge pipeline runs
---

**Depends on:** None.

Sol's generated port-forward helper scripts (`/tmp/sol-pf-<service>.sh`, spawned by `sol status`/`sol open`/`sol dev up`) have no lifecycle management: no cleanup on the parent session exiting, no staleness detection, and each wraps `kubectl port-forward` in a retry loop that respawns it indefinitely even against a cluster that no longer exists.

**Description:** Found 11 of these scripts running, some for 8+ hours, all pointed at a kubectl context (`sun-dev-lbendtly`) for an EKS cluster that had already been destroyed — confirmed via direct AWS investigation (zero EKS clusters exist in the account). Each script's retry loop meant `kill`-ing the `kubectl port-forward` child process alone was not sufficient to stop it; the parent shell script immediately respawned it. One of them (`sol-pf-loki.sh`, forwarding `svc/loki` to `localhost:3100`) directly caused the "already bound to port 3100" false failure that hit `soldev pipeline merge`'s post-merge test suite three separate times in one session (FRIC-011, FRIC-013, FRIC-012), each requiring manual recovery (reverting a local revert and re-pushing directly to `main`, bypassing the repo's own "changes must be made through a pull request" branch protection).

**Impact:** Any long-running local dev session that has ever pointed its kubectl context at a real cloud cluster and later torn that cluster down is left with orphaned, endlessly-retrying port-forward processes that silently shadow legitimate local services on the same ports (Loki, Postgres, Grafana, etc. all have fixed local ports) — with no indication to the user that this is happening, and no built-in way to clean it up short of manually finding and killing the wrapper shell scripts (not just the `kubectl` child processes).

**Remediation:**
1. Whatever generates `/tmp/sol-pf-*.sh` should track the PIDs it starts (e.g. a PID file per script, or a manifest under `$SOL_HOME`/a well-known state dir) so a future invocation can detect and kill a stale one before starting a new one for the same service.
2. Add a `sol dev down` / `sol status --cleanup`-style command (or extend an existing one) that kills all currently-tracked port-forward helpers.
3. Consider whether the retry loop should give up after N failed connection attempts (or after the target context/cluster is confirmed unreachable) rather than retrying forever — an indefinitely-retrying background process for a cluster that's been deleted has no legitimate use case.
