---
id: FRIC-025
type: dogfood-finding
severity: medium
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Port-forward state is a global singleton keyed only by service name, so two local workspaces collide on :8080

**Description:** Port-forward management names its files purely by logical service name — `pf-<name>.pid`, `/tmp/sol-pf-<name>.log`, `/tmp/sol-pf-<name>.sh` (`cli/sol/lib/sol_cli_state.ml:11-13`) — and the generated wrapper hardcodes the target namespace and `localhost:8080`:

```
kubectl --context k3d-sol-local port-forward -n '<ns>' 'svc/charge-svc' 8080:80
```

Deploying a second workspace while the first's forward is alive cannot start its own `charge-svc` forward. During this run I had to kill workspace 1's forward (and delete its `.pid`/`.sh`/`.log`) before workspace 2 could take :8080. A stale wrapper also keeps retrying with its baked-in namespace until the 30-consecutive-failure guard trips, so a forward left over from a renamed/deleted workspace silently serves or retries the wrong target.

**Impact:** Two workspaces cannot be exercised locally at once without manual cleanup; the failure is a port bind error or a silently wrong namespace, not a clear "this port belongs to workspace X". This undercuts the "grow a workspace / add a service" story on the local substrate.

**Remediation:** Key the pid/log/script filenames by workspace+service (or namespace+service) and detect an already-bound port, failing with a message naming the owning workspace. Expose a `sol local forwards` (or fold into `sol local status`) listing active forwards, and make `sol local infra down` clean up stale ones.

Related: FRIC-024 (local infra/status surface), REFAC-088 (destination seam for kube operations).

## Completion notes

- Keyed the per-service port-forward state by `namespace-service` in `cmd_up.ml` instead of the bare service name, so two workspaces' `charge-svc` forwards no longer overwrite each other's `pf-charge-svc.pid/.sh/.log`. Infra forwards (`kafka`, `postgres`, …) keep their fixed names — they are shared substrate, not per-workspace. `detect_stale` already reclaims `:8080` from a kubectl forward bound to a different namespace/target, so a second workspace now knowingly replaces the first rather than colliding.
- Not done in this pass (follow-ups, not required for the collision): a `sol local forwards` listing and workspace-scoped cleanup. `stop_all` remains global, which is correct for `sol local infra down` semantics.
- Verified by build; the end-to-end reclaim is exercised in the run's verification pass.
