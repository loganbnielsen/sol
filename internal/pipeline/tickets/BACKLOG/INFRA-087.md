---
id: INFRA-087
type: bug
severity: high
title: The platform install's cert-manager check can expire before the check runs on a fresh GKE Autopilot cluster
source: GCP Attempt 10 (main @ bc9062b0) — the platform install failed on it; FND-0060
---

**Depends on:** None.

**Related:** FND-0060 (the finding, with the frozen evidence), FND-0010 (the fix that removed the
earlier failure and exposed this one), `platform/cloud/modules/platform/main.tf`
(`helm_release.cert_manager`), `internal/qualification/records/2026-09-26-gcp-attempt10-fnd0010-live.md`.

## What was observed (FACT, live)

`sol cloud apply` created the cloud infrastructure and failed in the platform layer:

```
failed post-install: job cert-manager-startupapicheck failed: BackoffLimitExceeded
```

The check's own output is `error: timed out waiting for the condition`; there is **no `x509` line
in the bundle**. The check pod was scheduled ~15:17Z, pulled its image ~15:18Z, and its container
was not `Created`/`Started` until ~15:27:35Z — a **~9½-minute gap** — after which the Job deleted
the pod and hit its backoff limit. During that window the events show untolerated node taints,
pod-capacity pressure (`0/1`→`0/2`→`0/3` nodes available) and `TaintManagerEviction … Cancelling
deletion of Pod`. The three cert-manager workloads were `1/1 Running` at capture and the webhook's
CA secret was populated (`ca.crt`, created 15:16:35Z).

The release itself waited 9m20s where the pre-fix runs aborted at 414s, so the FND-0010 fix is not
the limiter: the **check's own 600s attempt window** expired.

## Why it matters

The install's outcome is decided by a timing relationship between a Sol-owned budget
(`startupapicheck.timeout`, 600s per attempt) and how long GKE Autopilot takes to make a *new*
node usable for that pod. A fresh cluster is the normal case for a cloud install, so the platform
definition can fail an install that would have succeeded had the check's window been observed
after the node was ready. Until this is resolved the GCP platform install does not reach `Ready`
on a fresh cluster, and with it the whole `Ready`-state lifecycle remains unobserved (it is the
first blocker for `PlatformInstalling → Ready`, and therefore for `Ready`-state destruction).

## Decision required: which lever, on whose evidence

The cause of the container-start delay is **not** established (FND-0060). Candidate directions,
none of them approved by this ticket:

1. **Make the harness's discriminator prove the mechanism first** (evidence-only): container
   start/termination timestamps, the node the check pod landed on with its taints and capacity at
   that moment, and the pod's `describe`. This is the cheapest next step and does not touch the
   product.
2. **Absorb the delay in the install budget** — e.g. a longer per-attempt window or a
   check-to-pod-start dependency — only once (1) shows the delay is the mechanism and bounds it.
3. **Make the cluster ready for the install burst before the check runs** (initial node count /
   capacity / tolerations) if (1) shows capacity rather than node initialisation is the constraint.

Do not inflate a timeout or change a node-pool setting on the strength of the current evidence:
the observed 9½-minute delay is real, but neither its cause nor its typical magnitude is known.

## Acceptance criteria

- The harness captures, for the check pod, the evidence in (1) — and one live run's discriminator
  states the mechanism as an observation rather than an inference.
- With the chosen lever, a live GCP run reaches `Ready` through the cert-manager boundary, or the
  remaining blocker is a *different*, separately classified failure.
- The FND-0010 question is re-answered at that point: either the check succeeds (TLS trust usable)
  or its failure names a cause other than this one.

## Not in this ticket

No change to the authority matcher or destruction semantics (FND-0058/INFRA-079 behaviour was
correct in this run). No FND-0010 timeout changes. No node-pool, firewall or DNS changes before the
discriminator in (1) lands.
