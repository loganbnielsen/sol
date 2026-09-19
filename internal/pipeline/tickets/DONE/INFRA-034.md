---
id: INFRA-034
type: bug
severity: high
title: A fresh install is judged by one readiness sample taken the moment the apply returns
source: HARDEN-002 Run 5 attempt 3, 2026-09-19 — a healthy platform was reported
  Unmet and the run failed
---

**Depends on:** None.

**Related:** ADR 0003 (readiness is what licenses the return to `Ready`), INFRA-032
(alloy, the defect that hid this one in attempts 1 and 2), HARDEN-002.

## What happens

`sol cloud apply` reported the platform as unmet immediately after a successful
apply:

```
[platform-apply] ok (171.0s)
error: platform readiness Unmet — cert-manager controllers: cert-manager controller,
  webhook, or cainjector is unavailable; ClusterIssuer: selected ClusterIssuer is not
  Ready; ingress-nginx: ingress-nginx controller is unavailable; Argo CD: an Argo CD
  controller is unavailable; Prometheus: Prometheus native readiness endpoint failed;
  Alloy: Alloy does not have every desired agent ready; Loki: Loki native readiness
  endpoint failed; Grafana: Grafana native health endpoint failed; Tempo: Tempo native
  readiness endpoint failed
```

Minutes later, on that same target, **every one of those components was healthy**:

| component | state minutes after the failure |
|---|---|
| cert-manager | 3 x `1/1` |
| ingress-nginx | `1/1` |
| Argo CD | 7 x `1/1` |
| Redpanda | 3 x `2/2` |
| Alloy | 4 x `2/2` |
| Loki / Grafana / Tempo | `2/2` / `3/3` / `1/1` |
| Prometheus | `2/2` |
| nodes | 4 x `Ready` (v1.36.4) |

The install was reported broken, **and privilege was relinquished first**, so the
operator is told the target failed when the platform is fine.

## Root cause

The readiness gate sampled once and never re-checked:

```ocaml
let readiness = Sol_cli_cloud_lifecycle.readiness ~cluster_issuer ... in
let summary = Sol_cli_cloud_lifecycle.readiness_summary readiness in
if summary <> "Ready" then (cleanup_bootstrap_access (); lifecycle_error ...)
```

`readiness` contains no wait, retry or sleep. Helm reporting a release as deployed
means the objects were created — not that the controllers behind them are serving.
On a fresh install every native readiness endpoint (`/-/ready`, `/ready`,
`/api/health`) is still starting, so a single sample taken the instant the apply
returns **cannot** describe the platform. This is not a rare race: it is the normal
condition of a fresh install.

### Secondary: the summary hides the one thing that could not fix itself

In the same run the ClusterIssuer genuinely was not Ready, and had a different
cause from the other eight: Let's Encrypt rejected the ACME registration
(`ErrRegisterACMEAccount`, `invalidContact` — the configured contact email was not
a valid address). Waiting would have fixed eight of the nine and left that one,
so the failure was correct in the end — but nine components were reported
together, and the only one an operator had to act on was buried among them.

## Remediation

Wait for readiness, bounded, reporting progress:

- `readiness` is re-sampled until every check is established, with a **900 s**
  default deadline and a 15 s interval;
- while waiting, the run prints how many checks are still unmet and how long it
  has been waiting, so the wait is evidence rather than a hang;
- on timeout the install still fails, with exactly the same unmet summary as
  before — a platform that never converges must not be reported Ready;
- `SOL_PLATFORM_READINESS_TIMEOUT_S` overrides the deadline (an operator knob, and
  what lets the harness assert the failing end without waiting fifteen minutes).

## Acceptance criteria

- A transient unmet readiness sample is waited out and the install reaches
  `Ready` instead of failing.
- A platform that never converges still fails, within the deadline, reporting the
  unmet summary.
- The run reports progress while it waits.
- The offline harness asserts both ends (the `readiness` phase is deliberately
  removed from the fail-closed injection loop, since readiness is a converging
  condition rather than a step that either passes or fails).
- No change to what `Ready` means: it is still reported only after every check is
  established, privilege is relinquished, and the provisioner is re-verified.

**Demo/example coverage:** No example change; the behaviour is visible in the
cloud-lifecycle tutorial's apply output.

**TypeScript parity:** No language-parity impact.
