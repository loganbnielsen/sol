---
id: AUDIT-019
type: audit-finding
severity: medium
source: project/audits/2026-06-10_audit.md
branch: AUDIT-019/rollout-secret-ref
worktree: ../sun-AUDIT-019-rollout-secret-ref
---

`rollout_doc` References `<name>-secrets` But `secret_doc` Generates `sun-secrets`

**Depends on:** AUDIT-016.

**Description:** `rollout_doc` in `cli/sun/lib/sun_cli_manifest.ml` (line 351) hardcodes `secretRef: name: %s-secrets` where `%s` is the service name (e.g., `charge-svc`), producing `charge-svc-secrets`. The shared secret name constant is `runtime_secret_name = "sun-secrets"`. `secret_doc` generates a Secret named `sun-secrets`. The name mismatch means Argo Rollout deployments will always fail to find their secrets even if `secret_doc` is correctly wired in. `deployment_doc` correctly uses `render_secret_key_refs` which references `sun-secrets`, but `rollout_doc` bypasses that and uses a hardcoded incorrect name.

**Impact:** Argo Rollout workloads (canary and blue-green) that have secrets configured will fail at pod startup with a `secret "<name>-secrets" not found` error. This will surface immediately when AUDIT-016 is fixed. The inconsistency between `rollout_doc` and `deployment_doc` makes the secrets model harder to reason about.

**Remediation:** Replace the hardcoded `secretRef: name: %s-secrets` block in `rollout_doc` with `render_secret_key_refs` (same as `deployment_doc`), using `runtime_secret_name` = `"sun-secrets"` consistently throughout.
