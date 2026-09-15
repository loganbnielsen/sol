---
id: INFRA-015
type: feature
severity: low
source: architecture discussion 2026-09-14 (spun off FEAT-079: -fn resource
  consumption made explicit, but isolated execution capacity deliberately
  deferred as a separate concern)
---

**Depends on:** FEAT-079 (resource requests/limits must be explicit and
configurable before isolating where those requests get scheduled is
meaningful).

**Related:** INFRA-014 (self-hosted substrate contract).

Give `-fn` executions an optional dedicated compute pool, separate from the
pool `-svc`/`-worker` run on, so a burst of function executions cannot
degrade long-lived workload latency/reliability merely by competing for the
same finite node capacity.

## Blocked On

Real `-fn` production usage that demonstrates this contention actually
happens. Nothing in the codebase demonstrates the need today — `-fn` has no
resource-consumption story explicit enough to even measure this against
(see FEAT-079) — and the fix, if built prematurely, adds real operational
surface (a second node pool, taints/tolerations, an infra-profile flag) for
a problem that may never occur at the scale Sol's early users run at. Do not
promote to `READY_FOR_ENGINEERING` until a workload demonstrates it.

## Problem

Sol's `-fn` executions currently share the exact same finite Kubernetes node
pool as `-svc`/`-worker`. Kubernetes' scheduler treats a `-fn` Pod
identically to any other Pod: if the cluster's allocatable capacity is
mostly consumed by long-lived `-svc`/`-worker` Pods, a burst of `-fn`
executions (especially with `scheduled_concurrency = "allow"` letting
several overlap) can either queue `Pending` or — depending on actual
requests/limits, memory pressure, and priority — degrade the resources
available to production services running in the same pool.

This is a **different** isolation concern from AWS Lambda's: Lambda doesn't
prevent a burst of invocations from overwhelming a shared downstream
dependency (DB, API, Kafka) — nothing does, that needs its own concurrency
limits regardless of execution model. What Lambda's model *does* give you is
narrower: a function burst cannot take down a service merely by consuming
the CPU/memory the service itself needs to keep running, because Lambda's
execution capacity is not drawn from the same pool as the service's. Current
Sol `-fn` has no equivalent boundary.

## Design (recorded now so it doesn't need re-deriving later)

Levels of increasing isolation, corresponding to increasing operational
cost — do not jump straight to the top:

- **Level 0 (current):** `-fn` Pods share normal cluster capacity with
  `-svc`/`-worker`. No isolation.
- **Level 1 (FEAT-079):** explicit resource requests/limits, explicit
  scheduled-concurrency policy. Scheduling *protection* (Sol makes an
  explicit decision instead of an ambient default), not isolation — a
  correctly-sized `-fn` can still compete for capacity with production
  Pods.
- **Level 2 (this ticket, once unblocked):** a dedicated execution node
  pool for `-fn`, using Kubernetes' existing native mechanisms — taints on
  the execution pool, tolerations + node affinity on generated `-fn`
  Pods — no custom scheduler. The execution pool could scale
  independently (including scaling to near-zero when idle), which is where
  `-fn` starts to gain an operational property resembling serverless
  without Sol pretending to implement a serverless platform.
- **Level 3 (rejected, do not build):** a real serverless backend (AWS
  Lambda, Cloud Run Jobs, etc.) as `-fn`'s execution target. This is a
  different platform integration, an order of magnitude more scope, and
  not what this ticket is about.

Level 2 should be an **infrastructure profile/capability**, not a default:
local development and small deployments should stay on one shared node
pool (Level 0/1 is sufficient there); a "serious production" target could
opt into a separate execution pool. Sol should not manufacture a new
scheduler when Kubernetes already has taints/tolerations/node affinity —
same "use the substrate's native representation, don't duplicate it"
principle FEAT-079 applied to the `CronJob` itself.

The honest framing to document once this exists: "`-fn` is a run-once
Kubernetes execution primitive. By default executions use shared cluster
capacity; targets may configure isolated execution capacity." Not "Sol
functions are serverless."

## Non-goals

- No custom Sol-level autoscaler for the execution pool — rely on the
  target's own cluster/node autoscaler (same posture as INFRA-014's
  "Kubernetes supplies scheduling and compute capacity" principle).
- No serverless backend integration (Level 3, rejected above).
- No change to `-svc`/`-worker`'s own node placement — this is additive,
  opt-in infrastructure for `-fn` only.
- No dependency-side isolation (DB connection limits, downstream rate
  limiting) — a separate, orthogonal concern this ticket does not solve.

## Acceptance criteria (once unblocked)

- A target can opt a `-fn` app into a dedicated execution node pool via
  Terraform/infra config, without changing anything for targets that don't
  opt in.
- Generated `-fn` manifests carry the toleration/affinity needed to land on
  that pool when configured; unchanged when not.
- A documented, real verification run shows a `-fn` burst no longer
  measurably affects a co-deployed `-svc`'s latency, using the isolated
  pool.
- Cost/scaling characteristics of the execution pool (including
  scale-to-near-zero behavior when idle) are documented.
