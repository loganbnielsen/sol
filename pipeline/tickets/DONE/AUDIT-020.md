---
id: AUDIT-020
type: audit-finding
severity: medium
source: project/audits/2026-06-10_audit.md
branch: AUDIT-020/k8s-name-lowercase
worktree: ../sun-AUDIT-020-k8s-name-lowercase
---

`namespace_of` Does Not Lowercase; Uppercase Workspace Names Produce Invalid Namespaces

**Depends on:** None.

**Description:** `k8s_name_of` in `cli/sun/lib/sun_cli_deployment_plan.ml` (line 137–138) maps underscores to hyphens but does not lowercase. `namespace_of` calls `k8s_name_of` on both workspace and domain names. Kubernetes namespace names must match the RFC-1123 DNS label pattern (lowercase alphanumeric + hyphens). A workspace directory named `MyApp` or `Acme_Corp` produces a namespace like `MyApp-payments` which the Kubernetes API server rejects. `workspace_name()` in `cmd_up.ml` uses `Filename.basename (Sys.getcwd ())` — the raw directory name without normalization. The `kubectl apply --dry-run=server` step catches this in the live path but the GitOps emit path (`--emit-to`) silently writes invalid YAML.

**Impact:** Users who create a workspace directory with mixed case get a confusing `kubectl apply` failure without a clear error from Sun. The GitOps path silently emits invalid manifests that Argo CD will reject with a cryptic error.

**Remediation:** Apply `String.lowercase_ascii` inside `k8s_name_of`:
```ocaml
let k8s_name_of name =
  String.map (fun c -> if c = '_' then '-' else c)
    (String.lowercase_ascii name)
```
Alternatively, add a pre-flight validation in `cmd_up.ml` and `cmd_deploy.ml` that checks the workspace name before generating any manifests and exits with a clear error message if uppercase characters are found.

