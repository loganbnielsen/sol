# FND-0060 — cert-manager's post-install check cannot run inside its attempt window on a freshly created GKE Autopilot cluster

- **Classification:** `VERIFIED_DEFECT` (live: the platform install failed on it in GCP Attempt 10,
  and the failure is reproduced by two Sol-owned budget numbers rather than by an external outage)
- **State:** `OPEN`
- **First identified:** 2026-09-26, GCP Attempt 10 (`main @ bc9062b0`)
- **Provider:** GCP (GKE Autopilot); the mechanism is Kubernetes scheduling/container-start latency,
  so AWS is not affected by *this* path and has not been examined for it
- **Derived ticket:** `INFRA-087`
- **Evidence class:** `LIVE` (bundle `/tmp/sol-gcp-qual-10`, 286 files)

## What is established (FACT — all from the frozen bundle)

- `sol cloud apply` created the cloud infrastructure (GKE `RUNNING`, Cloud SQL `RUNNABLE`) and then
  failed in the platform layer:
  `failed post-install: job cert-manager-startupapicheck failed: BackoffLimitExceeded`.
- The check's own output is a single line, `error: timed out waiting for the condition`. There is
  **no `x509` line anywhere in the bundle**: the pre-fix signature of FND-0010 is absent.
- Timeline for the check pod (`cert-manager-startupapicheck-xd44b`), from the Kubernetes events:
  `Scheduled` ~15:17Z after transient `FailedScheduling`; `Pulling`/`Pulled` ~15:18Z; then
  **nothing for ~9½ minutes**; `Created`/`Started` ~15:27:35Z; `SuccessfulDelete` →
  `Killing` → `BackoffLimitExceeded` ~15:27:37Z.
- While that pod waited, the node pool was under pressure and its nodes were tainted:
  `FailedScheduling … 0/1 nodes are available: 1 node(s) had untolerated taint(s)`, then
  `0/2 … 1 Too many pods, 1 node(s) had untolerated taint(s)`, then
  `0/3 … 1 Too many pods, 2 node(s) had untolerated taint(s)`, plus
  `TaintManagerEviction … Cancelling deletion of Pod`.
- The cert-manager workloads themselves were healthy at capture: controller, cainjector and webhook
  all `1/1 Running` (ages 11–12m), and `cert-manager-webhook-ca` held a populated `ca.crt`
  (created 15:16:35Z).
- The release was still waiting at **9m20s** where the pre-fix runs aborted at 414s — so the
  FND-0010 fix (a 1800s release wait with `startupapicheck.timeout` 600s × 2 attempts) is working as
  designed and is not the limiter here: the **check's own 600s attempt window** is what expired.

## What is inferred, and what is not established

- **INFERENCE:** the ~9½-minute container-start delay consumed the check's attempt window, so the
  check could never observe a healthy webhook. This explains the observed failure; it is not
  confirmed by the container's own output, which the bundle does not contain.
- **NOT ESTABLISHED:** *why* the container start was delayed. Taint-based handling and pod-capacity
  pressure are the only mechanisms the captured events show, and none of them is a documented
  root cause here.
- **NOT ESTABLISHED:** whether TLS trust was ever usable. The CA secret existed, but the bundle has
  no injected `caBundle` and no successful check run. The harness classified this specimen
  `SCHEDULING`; that label came from `FailedScheduling` warnings whose age equals the pods' age
  (i.e. the initial scheduling attempts, not a twelve-minute outage), so it should be read as
  `SCHEDULING`-adjacent rather than as a diagnosis.

## Why this is a defect rather than an environment quirk

Two numbers that Sol's own platform definition owns are in tension on a fresh cluster:
`startupapicheck.timeout` (600s per attempt) and the time GKE Autopilot needs to make a *new* node
usable for the check pod (observed here: ~9½ minutes of container start delay after the image was
already pulled). A fresh cluster is the normal case for a cloud install, so this is a lifecycle
timing question about the platform definition, not a one-off provider outage. The narrow statement
is: **the check's window can expire before the check runs, and nothing in the install budget
absorbs it.**

## What would establish the cause (candidate, not a decision)

The next attempt's discriminator should capture, for the check pod: its container start/termination
timestamps, the node it landed on with that node's taints and capacity at that moment, and the
`kubectl describe` of the pod (not only the events list). That turns the mechanism from inference
into observation. It is an evidence-only change to the harness; no product behaviour is implicated
by capturing it.

## Non-goals recorded

No remediation during the run that found this (per the run's own rule): no timeout inflation, no
node-pool change, no firewall change, no pod restart, no manual install step. The failed-install
destruction path worked (authority acquired, platform teardown ran, both roots empty, provider
inventory absent), so the specimen's cost was fully recovered.
