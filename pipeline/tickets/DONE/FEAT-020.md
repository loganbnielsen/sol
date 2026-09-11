---
id: FEAT-020
type: feature
severity: high
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: FEAT-020/gitops-secret-backend-refs
worktree: /home/lbendtly/Code/sun-FEAT-020-gitops-secret-backend-refs
---

Generate GitOps secret backend references instead of placeholder Secret values.

**Depends on:** FEAT-019.

**Problem:** `FEAT-019` prevents secret values from leaking into GitOps output by
redacting `stringData` values. That closes the immediate security hole, but the
generated GitOps artifact is still a placeholder Kubernetes `Secret` that an
operator must replace or mutate before Argo CD applies it.

For exported self-managed and managed customer-cloud GitOps, Sun should generate
the intended secret source of truth directly: External Secrets Operator or
Sealed Secrets references. Plain Kubernetes `Secret` placeholders should remain
a local/dev fallback, not the recommended GitOps interface.

**Goal:** Let a user configure a GitOps secret backend at the environment level
and have `sun deploy --emit-to` generate safe, applyable secret references with
no inline secret values.

**Remediation:**

1. Add a deployment-target secret backend model:
   - `kubernetes-placeholder` for current redacted `Secret` output.
   - `external-secrets` for External Secrets Operator.
   - `sealed-secrets` as a documented follow-up unless it fits cleanly.
2. Add CLI/env configuration for GitOps backend selection and backend-specific
   fields such as `secretStoreRef`, remote key prefix, and refresh interval.
3. Render `ExternalSecret` resources for every service secret key when
   `external-secrets` is selected.
4. Keep workload env wiring stable: pods should still consume a Kubernetes
   `Secret` named by Sun; ESO owns materializing that Secret.
5. Add tests proving GitOps output contains no non-empty `stringData`, includes
   the expected `ExternalSecret`, and preserves all secret keys.
6. Update deployment docs and generated CI comments to recommend the backend
   flow for GitOps.

**Out of scope:**

- Managing the external provider's secret values.
- Rotating credentials.
- Hosted Sun secret storage.
- Encrypting values into SealedSecrets if the first implementation chooses ESO
  only.

**Acceptance criteria:**

- `sun deploy --emit-to <dir> --secret-backend external-secrets ...` emits
  applyable `ExternalSecret` YAML and no non-empty `stringData`.
- Workload manifests continue to reference Kubernetes Secrets, not provider
  APIs directly.
- `--emit-plan-to` records the selected secret backend without secret values.
- Docs explain the current placeholder fallback and the recommended ESO GitOps
  path.

