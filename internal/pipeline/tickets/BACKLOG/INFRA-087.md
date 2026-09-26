---
id: INFRA-087
type: bug
severity: low
title: (WITHDRAWN) The cert-manager check's delay — superseded by INFRA-088
source: GCP Attempt 10 — withdrawn on forensic re-analysis of the same bundle
---

**Depends on:** None.

**WITHDRAWN 2026-09-26**, before any work started. This ticket was filed from FND-0060's reading of
Attempt 10, which took a ~9½-minute interval to be a scheduling/container-start delay. Re-analysis
of the same frozen bundle refutes that: the interval is cert-manager's own `check api --wait=10m`
window (122 webhook TLS handshake failures, every ~5s, 15:17:28 → 15:27:29), and the actual failure
is that the CA bundle was never injected because the controller and cainjector could never acquire
leader election in `kube-system` (GKE Autopilot denies it).

The real defect and the proposed fix are recorded in **FND-0010** and **INFRA-088**; FND-0060 is
marked `FALSIFIED`. Nothing here should be implemented.
