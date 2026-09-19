---
id: HARDEN-003
type: bug
severity: medium
title: Qualification evidence must establish the identity of its own observations
source: HARDEN-002 Run 5 Attempt 5 — a stale port-forward and a vacuous assertion,
  the same failure twice
---

**Related:** HARDEN-002 (the epic, its run records and its harness discipline),
INFRA-035 (a fake harness accepting any argv — same family), OBS-046.

## The invariant

> Qualification evidence must establish both the asserted condition **and** the
> identity/provenance of the observation used to establish it. A check that cannot
> demonstrate it is observing the intended target, endpoint, process, artifact, or
> output is not qualifying evidence.

and, for anything automated:

> A qualification assertion must be demonstrated capable of failing when its
> claimed condition is violated.

## Two incidents, one structural failure

They look unrelated. They are not.

**1. The observation targeted the wrong endpoint.** While qualifying observability
behaviour, this query returned nothing:

```text
query={namespace="monitoring"}  ->  0 streams
```

That read as "Alloy ships nothing to Loki" — a serious product defect, and one
worth stopping the run for. It was not true. The same target held 36,523 lines and
the Loki canary reported `entries_total=929, missing_entries_total=0`.

`kubectl port-forward svc/loki` had been established before the `PlatformUpdating`
re-entry restarted `loki-0`, and the forward kept serving the replaced instance:

```text
via svc/loki   : loki_distributor_lines_received_total = 366      (stale)
via pod/loki-0 : loki_distributor_lines_received_total = 36523    (actual)
```

The canary is what saved it: an independent endpoint whose *own* health metric said
the pipeline was fine, which made the contradiction impossible to ignore.

**2. The assertion targeted the wrong output channel.** An offline assertion in the
lifecycle harness grepped `LIFECYCLE_LOG` for a message the CLI prints to stdout.
`run_apply` sends tool output to `$log.out`, while `LIFECYCLE_LOG` holds only the
fake tools' invocations. The check could therefore neither pass nor fail on the
thing it claimed to test: it was vacuous, and would have "passed" even if the stage
it was guarding had run. Found while writing INFRA-039's fail-closed coverage.

Both are:

```text
measurement
    ↓
does not establish observation identity
    ↓
produces an apparently authoritative result
    ↓
can confidently certify something false
```

They differ only in which identity was skipped — endpoint, or output channel. The
second is arguably worse: a check that cannot fail is invisible in a green run, and
looks like coverage.

## What is needed

1. **Identity, recorded.** A behavioural row's evidence names what was observed and
   how it was reached. "I queried Loki" is not evidence; "I queried `pod/loki-0`
   after re-establishing the connection, and the canary's independent metric agrees"
   is. Where a name resolves through an indirection — a service, a proxy, a load
   balancer, a port-forward — the resolved endpoint is part of the evidence.
2. **A positive control** wherever an absence is the result, so "nothing found" is
   distinguishable from "nothing asked": a canary, a known recent event, the
   endpoint's own health metric.
3. **Fresh connections across mutations.** Anything that can replace the process
   behind a name invalidates a connection opened before it. Re-establish, or pin to
   the thing itself (the pod) rather than the thing that redirects (the service).
4. **Assertions that can fail.** For scripted checks, demonstrate the failure: feed
   the violated condition and confirm the assertion rejects it. Mutation testing is
   the natural mechanism, and the harness already has the tools for it
   (`FAIL_ON=`-style injection).
5. **A second source when a result is surprising.** On Attempt 5 one metric settled
   the contradiction; without it the run would have carried a false finding into the
   report and acted on it.

## Acceptance criteria

- The invariant and the assertion rule appear where an operator reads them (the
  procedure's harness discipline), not only in a run record.
- Behavioural rows record the observation's identity alongside the assertion, and
  absences carry a positive control.
- Automated qualification assertions can demonstrate failure; where practical the
  mechanism is a mutation test wired into CI, not a reviewer's diligence.
- Both incidents are recorded as instances of one failure, so the next operator
  recognises the shape rather than memorising two unrelated rules.

**Demo/example coverage:** Not applicable.

**TypeScript parity:** No language-parity impact.
