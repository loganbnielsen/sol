# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: GCP Qualification Attempt 14 — past the storage boundary, Autopilot admission is the frontier (2026-09-26)

- Ran from `ae47d777` (main, CI green; `d301426f` and all required ancestors present) on a fresh target `qual14/gcp/us-central1` → cluster `sol-qual-gcp-14`.
- **FND-0063 qualified live**: the real Terraform output was parsed, the project established and the quota observed — the lifecycle continued *past* the parser boundary, which is what INFRA-091 existed to make possible.
- **FND-0062's check qualified live**: `SSD_TOTAL_GB 100/1000 GiB used (900 GiB free)` against the declared 20 GiB; policy passed; `platform-prerequisites-apply ok (145.7s)` — past Attempt 12's stopping point. The nodes then took usage to 500 GiB, the exact wall Attempt 12 hit, with headroom left. The PVC-binding claim is *not* qualified (those components never applied).
- **First new blocker (FND-0064)**: GKE Autopilot's admission webhook refuses `helm_release.prometheus` (`hostNetwork`/`hostPID`) and `helm_release.redpanda` (`linux capability 'SYS_RESOURCE' on container 'tuning'`). A provider policy meeting Sol's platform defaults — a support-boundary decision, not a code defect, and nothing was repaired in-run.
- Evidence frozen before teardown; supported destruction from a *partially installed* platform (262 KiB of state → `platform-destroy ok (136.7s)` → disposable roots empty) with the authority bracket used once each way. Independent verification: no residue, `SSD_TOTAL_GB 0/1000`, durables standing.
- `INFRA-092` files the two harness gaps this exposed: an admission-denial classification ahead of ambient symptoms, and capturing the provisioner bindings after the prerequisites phase rather than only on the success path.
