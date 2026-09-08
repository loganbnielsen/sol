---
id: FRIC-003
type: dogfood-finding
severity: high
source: project/dogfood/RUN_2026-06-11.md
branch: FRIC-003/port-forward-restart-loop
worktree: /home/lbendtly/Code/sun-FRIC-003-port-forward-restart-loop
---

**Depends on:** None.

Port-forward dies after pod rollout restart and is not automatically revived

**Description:** The `kubectl port-forward` process started by `sun up` targets `svc/<name>` but in practice proxies to a specific pod endpoint. When a pod is replaced (by `kubectl rollout restart`, `sun up` image update, or any other rollout), the port-forward process exits. The dead PID is still recorded in `.sun/pf-<name>.pid`. On the next `sun up` invocation, the duplicate-guard (`port_forward_running`) may incorrectly detect the stale PID as alive (depending on PID reuse timing), or the new port-forward may bind successfully. The net effect is a silent window where `curl http://localhost:8080` fails with "connection refused" between when the pod restarts and when the engineer notices and manually restarts the port-forward.

**Impact:** After any pod replacement (rollout, `sun up` re-deploy, or manual restart), the local port-forward silently dies. An engineer debugging a service change will run `curl http://localhost:8080` and get "connection refused" with no explanation — `sun status` still shows the URL but does not verify the port-forward is alive. The engineer must manually run `kubectl port-forward` to restore access.

**Remediation:** Wrap the `kubectl port-forward` invocation in a shell restart loop and background it:
```bash
while true; do
  kubectl port-forward -n <ns> svc/<name> <local>:<remote> 2>>/tmp/sun-pf-<name>.log
  sleep 1
done
```
This ensures the port-forward automatically reconnects to the new pod after a rollout. Alternatively, in `sun status`, add a liveness check for each registered port-forward PID (using `kill -0`) and print a warning + suggested remediation for any that are dead.

**Code location:** `cli/sun/bin/cmd_up.ml` — `start_port_forward` function; the background process is launched directly without a restart wrapper.

## Review — automated checks passed
FRIC-003 port-forward restart loop correctly wraps kubectl port-forward in a while-true shell script, written at /tmp/sun-pf-<name>.sh, with setsid to survive shell exit. Both cmd_up.ml and cmd_dev.ml updated.
