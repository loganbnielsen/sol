---
id: CODE_LAYER-015
type: code-layer-finding
severity: medium
source: pipeline/audits/2026-09-09_code_layer_audit.md
---

# Add a pre-deploy runtime contract check phase

Sol currently discovers deployables by directory suffix plus `Dockerfile`, then
mostly learns runtime-contract failures after deploy.

Add the smallest `sol check` or pre-deploy check boundary that can validate
declared services before real deploy: required files, primitive shape, required
env keys, `/healthz` for services, and `/metrics` when Sol will annotate the pod
for scraping.

Acceptance:
- `sol check` or an equivalent shared library phase exists.
- Checks run without Kubernetes.
- Failures are actionable and reference the service path.
- The phase is usable by both `sol up` and `sol deploy`.
