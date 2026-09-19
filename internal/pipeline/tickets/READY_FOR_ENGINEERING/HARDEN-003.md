---
id: HARDEN-003
type: bug
severity: medium
title: A behavioural observation must prove it is querying the endpoint it intends to
source: HARDEN-002 Run 5 Attempt 5 — an empty Loki query nearly became a false product finding
---

**Related:** HARDEN-002 (the epic and its run records), INFRA-035 (the fake-kubectl
harness accepting any argv — a different boundary, same family), OBS-046.

## The finding

While qualifying observability behaviour on Attempt 5, this query returned
nothing:

```text
query={namespace="monitoring"}  ->  0 streams
```

That read as "Alloy ships nothing to Loki" — a serious product defect, and one
worth stopping the run for. It was not true. The same target held 36,523 lines,
and the Loki canary reported `entries_total=929, missing_entries_total=0`.

The observation was querying the wrong thing. `kubectl port-forward svc/loki`
had been established before the `PlatformUpdating` re-entry restarted `loki-0`,
and the forward kept serving the replaced instance:

```text
via svc/loki   : loki_distributor_lines_received_total = 366      (stale)
via pod/loki-0 : loki_distributor_lines_received_total = 36523    (actual)
```

The canary is what saved it: an independent endpoint whose *own* health metric
said the pipeline was fine, which made the contradiction impossible to ignore.

## Why this belongs in the repo rather than in a run report

This is a qualification-harness correctness problem, and it fails in the worst
direction: an empty result looks exactly like a broken capability. Every
behavioural row in the matrix is exposed to it — `sol logs`, metric and trace
queries, anything reached through a forward, a proxy or a load balancer. A
qualification procedure that can produce confident false findings is worse than
one that produces none, because the findings get acted on.

## What is needed

A behavioural observation must establish, and be able to show, that it is talking
to the endpoint it intends:

1. **A fresh connection per observation**, not one opened earlier in the run and
   reused across a platform mutation. If a forward must persist, it is
   re-established after anything that can replace the process behind it.
2. **Prefer the pod over the service** for a single-endpoint read, or verify the
   resolved endpoint (pod name/uid, or an identity the endpoint itself reports)
   before believing an empty or surprising answer.
3. **A positive control.** Each behavioural claim should be paired with something
   that must be present — a canary, a known recent event, a target's own health
   metric — so "nothing found" can be distinguished from "nothing asked".
4. **An independent second source** when the answer contradicts an expectation.
   On Attempt 5 the canary metric settled it in one command; the run nearly went
   the other way.

## Acceptance criteria

- The procedure documents the observation discipline above in the place an
  operator reads it, not in a run record.
- Where the harness performs a behavioural read, it re-establishes the connection
  and surfaces the endpoint identity it resolved.
- A behavioural row's evidence records both the query and the positive control.
- The failure mode is exercised: a stale endpoint must produce a visible
  discrepancy, not a plausible empty result.

**Demo/example coverage:** Not applicable.

**TypeScript parity:** No language-parity impact.
