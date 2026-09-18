---
id: INFRA-017
type: feature
severity: medium
source: architecture discussion 2026-09-15 (INFRA-016's real runs showed
  neither preregistered case actually tested post-admission runtime
  contention -- Case A fit within capacity, Case B was mostly a scheduler-
  admission test since Kubernetes only ever admitted 1/4 burst pods)
---

**Depends on:** INFRA-016 (done — established the end-to-end `sol fn run`
→ real concurrent Pods path works, and that neither tested case showed
material interference, but also that neither actually created serious
post-admission compute contention).

**Related:** INFRA-015 (this ticket's result is what INFRA-015 actually
needs before its own gate can be resolved either way).

Characterize what isolation contract Sol's shared-compute Kubernetes
model actually provides between `-fn` and `-svc`/`-worker` — as a
standalone question, not one predetermined benchmark case — starting from
Sol's actual resource-rendering semantics rather than an assumed shape.

## Problem

INFRA-016 answered a narrower question than "does shared compute provide
isolation." Reclassified honestly, its two cases were:

```text
Case A: requests fit, actual demand fits
        → coexistence test (passed)

Case B: requests don't fit
        → Kubernetes scheduler admission test (passed as expected —
          Kubernetes protects against overcommitted *requests*, which is
          well-understood behavior, not evidence about Sol specifically)

Missing: requests fit (so Kubernetes admits everything), but actual
         demand collectively exceeds node capacity
        → runtime isolation test — never run
```

The missing case is the one that would actually threaten `-svc`: workloads
Kubernetes agreed to schedule, then genuinely competing for the same
physical CPU. INFRA-016's own three-case framing (Case A / Case B /
missing case above) is the correct way to explain what that ticket did
and did not establish — carry it into this ticket's own writeup once
this work is done, rather than let "INFRA-016 passed" imply more than it
showed.

Do not treat "shared compute is generally isolated" as established.
INFRA-016 gives high confidence that the end-to-end path works and that
correctly-configured happy-path coexistence is fine; it gives no evidence
about genuine post-admission contention, memory pressure, or a `-svc`
running anywhere near its own resource ceiling.

## Sol's actual resource-rendering semantics (answer this before designing
## any test shape — do not assume)

**Already inspected as part of filing this ticket, recorded here so the
next step doesn't redo it:** `cli/sol/lib/sol_cli_manifest_yaml.ml`'s
three workload renderers — `deployment_doc` (line 346, `-svc`/`-worker`
non-canary), `rollout_doc` (line 525, Argo Rollouts canary), and
`cronjob_doc` (line 885, `-fn`) — each take a single `~cpu` and `~memory`
labeled argument (no separate limit parameter exists in any of the three
signatures) and render both `resources.requests` and `resources.limits`
from that same value:

```yaml
resources:
  requests:
    cpu: <cpu>
    memory: <memory>
  limits:
    cpu: <cpu>       # same value, not independently configurable
    memory: <memory> # same value, not independently configurable
```

**Sol currently renders `request == limit` for both CPU and memory,
universally, across `-svc`, `-worker`, and `-fn`.** This is not
configurable through any current Sol surface — producing a divergent
request/limit pair would require hand-editing the generated manifest
outside Sol entirely, which is not a "normal Sol configuration" scenario
and should not be the shape of this ticket's test.

Consequences worth confirming/recording as this ticket's first real
acceptance criterion (not re-deriving from scratch, but verifying against
a real rendered+applied manifest, since a source read is not the same as
observed cluster behavior):

- Every Sol-generated container should get Kubernetes `Guaranteed` QoS
  class (equal requests/limits for both CPU and memory is the condition
  for it) — confirm with `kubectl get pod <p> -o jsonpath='{.status.qosClass}'`
  against a real deployed workload, not just the rendering source.
- Because `request == limit` for CPU, a Sol `-fn`'s aggregate CPU ceiling
  is a hard cgroup enforcement, not just an observed absence of spiking in
  one experiment — so the "under-request but actually consume more"
  overcommit scenario INFRA-016 didn't test is not reachable through Sol's
  own config surface today. Don't design a test case around it.
- The actual open question given `Guaranteed` QoS everywhere: under real
  node-level CPU pressure between multiple `Guaranteed` Pods (all with
  hard ceilings, none throttleable below their own limit by priority),
  how does CFS fair-share arbitration behave when several Pods' *combined*
  limits exceed the node, and can a `-fn` burst still meaningfully steal
  cycles from a `-svc` running close to its own ceiling even though
  neither Pod individually exceeds its declared resources? This is a real
  contention question `Guaranteed` QoS does not answer by itself.

## Design

**Local-first, not CI-first.** INFRA-016 encoded characterization as a
`workflow_dispatch` GitHub Actions job, which was right for proving the
real end-to-end Sol path (fresh runner, no local Docker/k3d access in
this dev sandbox, reproducible for anyone who checks out the repo) but
wrong for iterative systems characterization — each iteration cost a
~15-20 minute round trip through push/dispatch/wait/inspect-runner, and
CI's pass/fail framing doesn't fit an activity whose actual output is
"what happened," not "did it stay green" (INFRA-016's own final-case
drain-wait timeout is the concrete example: the experiment had already
produced valid, complete results, and CI still reported ❌ for an
unrelated cleanup-timing reason).

This work should produce (or make a deliberate call not to yet build) a
local, fast-iteration harness: fresh k3d cluster with a known/fixed
resource envelope (explicit CPU/memory constraints on the cluster itself,
not "whatever the runner happens to have"), calibrated workloads, and a
repeatable "change scenario → run → inspect results" loop measured in
single-digit minutes, not CI round trips. Once a specific isolation
*invariant* is established this way (e.g. "a correctly-sized `-fn` burst
never causes a `Guaranteed`-QoS `-svc` to miss its SLO"), a narrow,
fast regression check for that specific invariant can graduate into CI —
but the exploratory characterization work itself should not live there
while it's still exploratory. This machine (the current dev sandbox) has
no reliable local Docker/k3d access — building/running this harness
needs either the user's own machine (with Docker actually running, and
ideally a fresh cluster rather than the existing week-old dev one, which
has accumulated unrelated cruft and an unhealthy Redpanda) or a different
environment with real container access. Do not assume this can run in the
current sandbox without that being explicitly arranged first.

**Calibrate the `-svc` workload, don't leave it trivial.** INFRA-016's
`charge-svc` was a ~3-5ms near-no-op — useful for detecting scheduler
noise, but far below the CPU utilization where real contention would show
up. This ticket's `-svc` should run genuinely CPU-bound work sustained at
roughly 70-80% of its own declared limit, so there's real headroom to
observe degradation into, and real demand to actually compete for cycles
during a concurrent `-fn` burst.

**Fix the verdict threshold.** INFRA-016's 1.5x-relative-to-baseline p99
criterion is misleading at both ends — a baseline-vs-burst move from
5.5ms to 7.7ms reads as "+39%!" when no product SLO cares, while an
80ms→118ms move would pass the same 1.5x check while plausibly violating
a real SLO. Use an explicit SLO-style threshold set:

```text
FAIL if
  p99 > baseline * degradation_ratio
  OR p99 > absolute_slo_ms
  OR error_rate > error_budget
  OR throughput < expected_floor
```

**Broaden the signal set beyond readiness.** `ready == desired` is a
catastrophic-failure check, not a sufficient isolation signal by itself.
Record latency (p50/p95/p99), throughput, error rate, `-svc` CPU
consumption, CPU throttling (if available), and `-fn` startup/`Pending`
duration — `ready` stays a useful sanity check, just not the headline
metric.

**Test memory pressure as a separate phase, not folded into the CPU
case.** CPU contention degrades gracefully (processes get less of it);
memory contention does not (reclaim → pressure → eviction/OOM — something
dies). These need separate scenarios with separate failure criteria, not
one combined "resource contention" case.

## Remediation

Suggested order (each step's output should inform whether/how the next
step is actually needed — don't treat this as a rigid checklist to
execute blindly):

1. Confirm the resource-rendering findings above against a real deployed
   workload (`qosClass`, actual applied `resources` block) rather than
   relying on the source read alone.
2. Build (or explicitly decide not to yet build, and say why) a local
   fast-iteration characterization harness: fixed-envelope k3d cluster,
   calibrated hot `-svc`, scriptable scenario definitions, results written
   somewhere inspectable (a results file, not just terminal scrollback).
3. Run a genuine post-admission CPU contention scenario: `-fn` burst sized
   so Kubernetes admits all of it (requests fit) while the `-svc` is
   already running hot (~70-80% of its own limit) and the `-fn` burst's
   own actual demand adds real competing load. Use the SLO-style
   threshold set and broadened signal set above.
4. Run a memory-pressure scenario as a separate phase.
5. Record which Kubernetes mechanisms (QoS class, CFS fair-share,
   anything else observed) actually provided protection, and where they
   stopped providing it, if anywhere.
6. Decide, with evidence: nothing further needed / better default
   `-fn` resource sizing / `PriorityClass` (a Level-1.5 mechanism, cheaper
   than a dedicated node pool — `-svc`/`-worker` higher priority than
   `-fn`, encoding "serving traffic matters more than starting an
   opportunistic function immediately") / `ResourceQuota` / a dedicated
   node pool (INFRA-015's original proposal, still the most expensive
   option and should still be last resort).
7. Update INFRA-015 with whatever this establishes — same discipline as
   INFRA-016: promote with a specific mechanism if real interference is
   found, or record the evidence and keep it gated if not.

## Non-goals

- Does not implement any isolation mechanism (`PriorityClass`,
  `ResourceQuota`, dedicated node pool) — characterization only, same as
  INFRA-016. A decision to implement one is a separate ticket informed by
  this one's result.
- Does not reopen or re-run INFRA-016 — that experiment's own scope
  (end-to-end path verification, moderate/aggressive request-fit cases)
  is complete and its result stands.
- Does not require building a permanent `soldev` characterization
  subcommand — a scripted local harness (however invoked) is sufficient;
  formalizing it into first-class tooling is optional, not required for
  this ticket's acceptance.
- Does not test cross-node or multi-node-pool scenarios, or dependency-
  side (DB/Kafka) contention — same scope boundary as INFRA-016.

## Acceptance criteria

- The resource-rendering findings above are confirmed against a real
  deployed workload, not left as a source-only claim.
- A genuine post-admission CPU contention scenario actually runs — a
  `-fn` burst that Kubernetes admits in full while a calibrated,
  genuinely-hot `-svc` is under sustained load — and produces real
  recorded numbers against the SLO-style threshold set, not the bare
  1.5x-relative check.
- A separate memory-pressure scenario runs and produces real recorded
  numbers.
- The report explicitly states which Kubernetes mechanisms (QoS class,
  CFS behavior, anything else) provided observed protection and where, if
  anywhere, they broke down — not just a pass/fail verdict.
- INFRA-015 is updated based on the result, following the same rule
  INFRA-016 used: promoted with a specific mechanism if interference was
  found, or left in `BACKLOG` with the evidence recorded if isolation was
  found adequate.
- The characterization work itself does not live as a CI merge-gate or
  scheduled job while still exploratory; if a specific invariant is
  established and worth a permanent regression check, that check is
  scoped narrowly rather than re-running the whole characterization on
  every PR.
