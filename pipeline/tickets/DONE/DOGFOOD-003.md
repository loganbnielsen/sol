---
id: DOGFOOD-003
type: feature
severity: high
source: product-planning-2026-06-11
branch: DOGFOOD-003/local-cluster-deploy
worktree: /home/lbendtly/Code/sun-DOGFOOD-003-local-cluster-deploy
---

Local cluster deploy loop dogfood.

**Depends on:** DOGFOOD-002.

**Problem:** Sun promises that local dev mirrors production. The generated app
must deploy into the local cluster through the same manifest/deployment plan
machinery used by customer-cloud deploys.

**Goal:** Prove `sun up`, `sun status`, and service reachability against the
local k3d cluster.

**Remediation:**

1. Run `sun up` from the dogfood workspace.
2. Confirm images build, push to the local registry, render manifests, validate,
   and apply.
3. Confirm `sun status` shows all expected workloads.
4. Confirm the HTTP service is reachable through the generated local endpoint.
5. Confirm worker/fn workloads have expected config and secret references.
6. Record any divergence between `sun dev run` and in-cluster behavior.

**Acceptance criteria:**

- `sun up` succeeds without hand-written Kubernetes manifests.
- Deployed service responds successfully.
- Status output identifies namespace, workload, readiness, and endpoint.
- Any local/prod parity gaps are captured as follow-up tickets.
