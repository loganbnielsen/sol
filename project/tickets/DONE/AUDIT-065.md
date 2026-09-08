---
id: AUDIT-065
type: audit-finding
severity: medium
source: direct investigation, 2026-09-07 — root cause of the recurring "kubectl port-forward already bound to port 3100" false failure hit 3 times during this session's merge pipeline runs
branch: AUDIT-065/pin-portforward-context
worktree: ../sun-AUDIT-065-pin-portforward-context
pr: https://github.com/loganbnielsen/sol/pull/148
---

**Depends on:** None.

Sol's generated port-forward helper scripts (`/tmp/sol-pf-<service>.sh`, spawned by `sol status`/`sol open`/`sol dev up`) have no lifecycle management: no cleanup on the parent session exiting, no staleness detection, and each wraps `kubectl port-forward` in a retry loop that respawns it indefinitely even against a cluster that no longer exists.

**Description:** Found 11 of these scripts running, some for 8+ hours, all pointed at a kubectl context (`sun-dev-lbendtly`) for an EKS cluster that had already been destroyed — confirmed via direct AWS investigation (zero EKS clusters exist in the account). Each script's retry loop meant `kill`-ing the `kubectl port-forward` child process alone was not sufficient to stop it; the parent shell script immediately respawned it. One of them (`sol-pf-loki.sh`, forwarding `svc/loki` to `localhost:3100`) directly caused the "already bound to port 3100" false failure that hit `soldev pipeline merge`'s post-merge test suite three separate times in one session (FRIC-011, FRIC-013, FRIC-012), each requiring manual recovery (reverting a local revert and re-pushing directly to `main`, bypassing the repo's own "changes must be made through a pull request" branch protection).

**Impact:** Any long-running local dev session that has ever pointed its kubectl context at a real cloud cluster and later torn that cluster down is left with orphaned, endlessly-retrying port-forward processes that silently shadow legitimate local services on the same ports (Loki, Postgres, Grafana, etc. all have fixed local ports) — with no indication to the user that this is happening, and no built-in way to clean it up short of manually finding and killing the wrapper shell scripts (not just the `kubectl` child processes).

**Root cause, precisely (found by reading `cli/sol/lib/sol_cli_port_forward.ml`/`sol_cli_state.ml` and their call sites — this is more specific than it first looked, and changes the fix):**

The PID-tracking and cleanup machinery described below as "missing" in the original write-up **already exists**: `Sol_cli_port_forward.start` writes a PID file (`~/.local/share/sol/pf-<name>.pid`, the *wrapper script's* PID via `echo $$`) and `stop_all ()` reads every such file and kills the recorded PID. It's wired into `cmd_dev.ml`'s `dev_up`/`dev_down` (`sol dev up` calls `stop_all ()` first specifically to "kill stale port-forwards from previous sessions"). So this part of the design is sound — for the **local k3d dev loop** it's meant to cover.

The actual bug: `start`'s generated wrapper script (`sol_cli_port_forward.ml`'s `start` function) runs `kubectl port-forward -n <ns> <target> <port>:<port>` **with no `--context` pinned**. Every iteration of its `while true; do kubectl port-forward ...; sleep 1; done` retry loop re-reads whatever the *ambient current kubectl context happens to be at that moment* — it is not fixed to the context that was active when the script was created. So: start `sol dev up` (or `sol up` against a cloud target) while context is `k3d-sol-local`, later run `kubectl config use-context <something-else>` for unrelated work (e.g. pointing at a cloud dogfood cluster) without running `sol dev down` first, and every already-running port-forward silently starts retrying against the *new* context on its very next retry cycle — including one that no longer exists. This is exactly what happened: local-dev-started port-forwards ended up pointed at `sun-dev-lbendtly` (EKS) after that context became current, then kept retrying for 8+ hours after that cluster was destroyed. `stop_all()`/`sol dev down` never ran across that whole window because nothing prompted it to.

**Remediation:**
1. Pin the context at creation time: capture `kubectl config current-context` when `start` generates the wrapper script and bake it into the `kubectl port-forward --context <captured>` invocation, so a later ambient `use-context` elsewhere can never silently redirect an already-running port-forward. This is the actual bug and the highest-value fix.
2. Given #1, also make the retry loop give up after N failed attempts (or after confirming via `kubectl --context <captured> cluster-info`/similar that the pinned context is unreachable) rather than retrying forever — even pinned to the *right* context, a cluster that's since been destroyed has no legitimate reason for an indefinite retry loop.
3. Consider whether `sol up`/`sol status`/`sol open` (not just `cmd_dev.ml`'s `sol dev up`/`down`) should also call `Sol_cli_port_forward.stop_all ()` before starting new port-forwards, or whether that's already implicitly handled well enough by `detect_stale`'s narrower same-port check — investigate before adding a second cleanup call site if `detect_stale` already covers the case adequately once #1 lands.

## Review — automated checks passed
Root cause fixed: kubectl context is now pinned at port-forward creation time (captured via Sol_cli_kubectl.config_current_context, quoted correctly, gracefully omitted if none set), and the retry loop gives up after 30 consecutive fast failures instead of retrying forever. Independently re-verified live against the real k3d-sol-local cluster: confirmed a switched ambient context does NOT redirect an already-running port-forward, and confirmed the give-up-after-30 path fires correctly with proper PID-file cleanup. Build and diff scope clean.
