---
id: CODE_LAYER-022
type: feature
severity: medium
source: CODE_LAYER-015 closure (pre-deploy checks intentionally stop at static workspace validation)
---

**Depends on:** None.

Add a real post-deploy smoke check for the runtime endpoints that `sol check` intentionally does not verify statically: `GET /healthz` and `GET /metrics`.

## Problem

`sol check` / the shared pre-deploy phase is static and intentionally does not probe runtime endpoints (CODE_LAYER-015). The service and worker frameworks guarantee those endpoints, but nothing actually verifies a deployed workload answers them. A framework regression, a misconfigured container command, or a bad health path would only be discovered by a human noticing a failed rollout or missing metrics.

Static source greps for `/healthz` or `/metrics` are not a valid substitute: correctly built services may not mention those strings at all, because `Sol_svc.Service` and `Sol_worker.Worker` register them internally.

## Goal

A check that runs against a real deployed workload (not a source tree) and fails clearly if the runtime contract is broken.

## Remediation

- Prefer extending the existing golden-path/docker smoke CI with a deployed scaffolded service (e.g. the `charge_svc` example) and probing:
  - `GET /healthz` returns 200
  - `GET /metrics` returns 200 with Prometheus-format output
  - optionally a worker's `GET /metrics` on its metrics port
- If CI cannot run a cluster, add an explicit `sol doctor` / post-deploy probe command that operators and CI can run against a live environment.
- Do not implement this as static string matching in `sol check`.

## Acceptance criteria

- A check fails when a deployed service does not answer `/healthz` or `/metrics` correctly.
- The check runs against a running pod/workload, not source files.
- Failure output names the workload and the endpoint that failed.
- The static `sol check` phase remains unchanged and Kubernetes-free.
