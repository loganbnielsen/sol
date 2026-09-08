---
id: FRIC-001
type: ux-finding
severity: high
source: project/dogfood/RUN_2026-06-10-full.md
branch: FRIC-001/port-forward-conflict
worktree: ../sun-FRIC-001-port-forward-conflict
---

**Depends on:** None.

`sun up` prints port-forward success URL even when the port-forward process dies immediately due to port conflict

**Description:** When port 8080 is already held by a prior workspace's `kubectl port-forward` process, `sun up` launches a new `kubectl port-forward` that fails immediately with "bind: address already in use". The failure is silently logged to `/tmp/sun-pf-<name>.log`. `sun up` then unconditionally prints `→  http://localhost:8080  (port-forward running in background)` regardless of whether the process stayed alive. The PID file `.sun/pf-charge-svc.pid` is written with a PID that is already dead. The existing duplicate-guard (`port_forward_running`) only checks the current workspace's PID file — it does not detect a competing port-forward process from a different workspace directory.

**Impact:** An engineer who has a prior workspace still deployed runs `sun up` for a new workspace. The deploy succeeds, rollouts complete, and the success line with the URL looks correct. `curl http://localhost:8080/health` returns `ok` — but it is coming from the old workspace's service, not the new one. The engineer has no idea they are hitting the wrong service and may spend significant time debugging unexpected behavior. There is no warning, no error, and no indication that the port-forward failed.

**Remediation:** In `cli/sun/bin/cmd_up.ml`, after calling `start_port_forward`, add a brief liveness check: sleep 200ms, then re-read the PID from `.sun/pf-<name>.pid` and verify the process is still alive (`kill -0`). If the process is dead, read `/tmp/sun-pf-<name>.log` and print a warning:
```
  warning: port-forward for charge-svc failed (port 8080 may be in use by another workspace).
           See /tmp/sun-pf-charge-svc.log for details.
           Run: kill $(lsof -ti:8080) && sun up
```
Do not print the `→ http://localhost:8080` success line if the liveness check fails. Optionally, add a `--port` flag to `sun up` so a user with multiple workspaces can choose a non-conflicting port (e.g. `sun up --port 8081`).

