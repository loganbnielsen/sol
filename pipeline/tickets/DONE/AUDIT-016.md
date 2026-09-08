---
id: AUDIT-016
type: audit-finding
severity: high
source: project/audits/2026-06-10_audit.md
branch: AUDIT-016/secret-resource-emit
worktree: ../sun-AUDIT-016-secret-resource-emit
---

`Secret` Resource Never Emitted; `secret_keys` in `sun.toml` Causes CrashLoopBackOff

**Depends on:** AUDIT-015.

**Description:** `secret_doc` is declared in `sun_cli_manifest.mli` and defined in `sun_cli_manifest.ml` but is never called from `render`, `render_spec`, or any executor. No `Secret` resource is emitted for any workload. `render_secret_key_refs` correctly generates individual `secretKeyRef` env entries referencing `sun-secrets`, but those entries fail at pod startup because the Secret does not exist. A workspace operator who sets `secrets = ["POSTGRES_URL"]` in `sun.toml` will get pods in CrashLoopBackOff with a `secret "sun-secrets" not found` error.

**Impact:** The secrets mechanism is non-functional end-to-end. Users who attempt to use `sun.toml` secrets cannot deploy. The framework's security story is compromised because the escape hatch silently breaks deployments.

**Remediation:** Call `secret_doc` from `render_spec` (and `render`) to emit the Secret resource alongside the workload resources. Include the Secret in `workload_yaml`. Secret values should be injected by the operator at apply time via `sun secret set` or environment substitution.
