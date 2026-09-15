---
id: INFRA-016
type: feature
severity: high
source: architecture discussion 2026-09-15 (refining INFRA-015's "wait for a
  real user to hit this" gate into a testable, pre-registered experiment)
---

**Depends on:** FEAT-079 (done — `sol fn run` is this spike's burst-firing
mechanism).

**Related:** INFRA-015 (this spike's result decides whether INFRA-015 gets
promoted, what mechanism it actually specifies, or whether it stays
deliberately un-built).

Characterize whether Sol's shared-node-pool architecture provides adequate
isolation between bursty `-fn` execution and a long-lived `-svc`/`-worker`
workload, under plausible (not contrived) concurrency — before deciding
whether INFRA-015's dedicated node pool, or some cheaper mechanism, is
actually needed.

## Problem

INFRA-015 is currently gated on "a workload demonstrates this contention
actually happens" — but that is too weak a gate for an infrastructure
safety property Sol can deliberately test. The real question is not "has
this happened in production yet" (a user discovering it the unpleasant way
is not a design process), it is:

> Under plausible `-fn` concurrency, does the shared-compute architecture
> provide adequate isolation for long-lived workloads?

That question is testable today, locally-in-CI, without waiting for a real
deployment to get hurt.

## Design

**Define failure criteria before running anything.** "Material
degradation" is defined here, in this ticket, not discovered after the
fact by eyeballing a percentile that moved:

- **Latency:** the `-svc`'s p99 request latency during the `-fn` burst
  window exceeds **1.5x** its own pre-burst baseline p99, sustained for the
  whole burst window (not a single-sample spike).
- **CPU throttling:** `container_cpu_cfs_throttled_periods_total` for the
  `-svc` container shows a nonzero throttling rate during the burst window
  that was zero (or negligible) at baseline.
- **Scheduling/availability:** the `-svc`'s desired replica count is not
  fully `Running` at any point during the burst window (a replica evicted,
  `OOMKilled`, or stuck `Pending`).

Any one of these three counts as "material interference" — the experiment
does not require all three.

**Two test cases, not one:**

- **Case A — correctly configured:** `-fn` requests/limits sized to fit
  within the node's genuinely spare capacity alongside the `-svc`'s own
  request. This is the "well-behaved" case; if isolation fails here, that's
  a strong signal.
- **Case B — aggressive but valid:** `-fn` concurrency and per-execution
  resource requests that are individually reasonable (nothing
  misconfigured, nothing pathological) but collectively saturate or exceed
  the node's spare capacity when they overlap — e.g. N concurrent `sol fn
  run` invocations whose combined CPU request meets or exceeds what's left
  after the `-svc`'s own request. This is the case that matters: a
  developer doing something completely ordinary (firing a few functions
  around the same time) should not be able to accidentally take down a
  production service.

**This ticket does not presuppose the fix is a dedicated node pool.**
INFRA-015 (or whatever ticket this spike's result points to) owns the
*problem* — protect long-lived workloads from bursty ephemeral execution —
not a pre-chosen *mechanism*. If Case A and Case B both show acceptable
isolation with correctly specified Kubernetes resource requests/limits
(FEAT-079/BUG-031 already made those configurable for `-fn`), a dedicated
pool may be genuinely unnecessary for early Sol, and this spike's report
should say so plainly rather than build infrastructure looking for a
justification. If either case shows material interference, the result
should identify the *cheapest* mechanism that would have prevented it
(`PriorityClass`, `ResourceQuota`, more conservative default `-fn`
requests, cluster-autoscaler headroom, or — only if nothing cheaper closes
the gap — a dedicated node pool) rather than jumping straight to the most
expensive option.

## Remediation

Run the experiment in CI (this sandbox has no local Docker/k3d access —
GitHub Actions' `ubuntu-22.04` runners do, and `golden-path-smoke` already
proves the `sol local infra up` + real cluster pattern works there), as a
new `workflow_dispatch`-triggered job (not on every push — this is a spike
report, not a merge gate):

1. Scaffold a workspace with one `-svc` requesting a known `cpu`/`memory`
   (e.g. `500m`/`512Mi`) and one `-fn` for firing bursts, deployed to the
   same node pool (today's only pool — nothing to configure, that's the
   point).
2. Generate sustained load against the `-svc` (plain `curl` timing loop —
   no new load-testing dependency needed) for a baseline window; record
   p50/p95/p99 from the samples and the CPU-throttling rate from
   Prometheus (already provisioned by `sol local infra up`) over the same
   window.
3. Case A: fire a burst of `sol fn run` invocations sized to fit spare
   capacity, continuing the same `-svc` load generator throughout; record
   the same signals for the burst window.
4. Case B: repeat with an aggressive-but-valid concurrent burst that
   saturates/exceeds spare capacity; record the same signals.
5. Compare each case's burst-window signals against the pre-defined
   criteria above and print a clear per-case verdict (interference
   detected / not detected, with the actual numbers) in the job log.
6. If the `container_cpu_cfs_throttled_periods_total` metric is not
   actually available from this cluster's Prometheus (chart defaults can
   vary), the job must say so explicitly rather than silently reporting
   "no throttling detected" — a missing signal is not the same as a clean
   result.

## Non-goals

- Does not build INFRA-015's (or any) isolation mechanism — this ticket
  only characterizes whether one is needed and, if so, which class of
  mechanism.
- Not a merge-gating CI check — `workflow_dispatch` only, run on demand.
- Does not test dependency-side contention (a `-fn` burst overwhelming a
  shared Postgres/Kafka) — compute isolation only, matching INFRA-015's
  own scope.
- Does not test cross-node or multi-node-pool scenarios — single shared
  pool only, since that's the only thing that exists today.

## Acceptance criteria

- Failure criteria (the three above, or a revised version reasoned through
  in this ticket's completion notes) are recorded before the experiment
  runs, not fitted to the result afterward.
- Both Case A and Case B actually execute against a real Kubernetes
  cluster and produce recorded numbers, not simulated/assumed ones.
- A clear verdict for each case: material interference detected or not,
  against the pre-registered criteria.
- If interference is detected in either case, the report names the
  cheapest candidate mechanism that would plausibly close the gap, not
  just "build INFRA-015."
- INFRA-015 is updated based on the result: promoted with a specific
  mechanism (not necessarily a dedicated node pool) if interference was
  found, or left in `BACKLOG` with the evidence recorded if isolation was
  found adequate.
