---
id: FEAT-019
type: audit-finding
severity: high
source: dogfood/2026-06-11_DOGFOOD-005_customer_cloud_contract.md
branch: FEAT-019/gitops-secret-redaction
worktree: /home/lbendtly/Code/sun-FEAT-019-gitops-secret-redaction
---

GitOps YAML (`sun deploy --emit-to`) emits `kind: Secret` with plain-text values.

**Depends on:** None.

**Problem:**

`render_spec` in `sun_cli_deployment_plan.ml` already strips user-defined secret
values (`spec.secrets`) to `""` before calling `secret_doc`. But `secret_doc`
prepends `default_secrets` (which includes a hardcoded `POSTGRES_URL` dev value)
unconditionally. In GitOps mode those default values land in the emitted YAML:

```yaml
kind: Secret
stringData:
  POSTGRES_URL: "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
```

Any value that appears in `stringData` in a committed manifest is a credential
in plain text. Even though this particular value is only the dev default, the
design allows real values to leak the moment `default_secrets` is extended to
read live cluster state.

**Remediation:**

1. Add a `~redact:bool` parameter to `Sun_cli_manifest.secret_doc`. When
   `redact = true`, emit all secret values — both `default_secrets` and
   `extra_secrets` — as empty strings. Emit a YAML block comment above
   `stringData` listing the keys that must be populated before applying:

   ```yaml
   # Populate these values before committing or applying.
   # Use `sun secret set <KEY> --env <env>` or your secrets manager.
   stringData:
     POSTGRES_URL: ""
   ```

2. Add `~redact:bool` to `Sun_cli_manifest.emit_to_dir` and thread it through
   to `secret_doc`. Pass `~redact:true` from `Sun_cli_executor.gitops`.
   `local` and `direct` executors continue to pass `~redact:false`.

3. No change to `render_spec` signature needed — the redaction decision lives in
   the executor (it knows the deployment mode), not in plan rendering.

4. Update `docs/deployment/self-hosted-substrate-contract.md` to describe the
   redacted-secret contract: keys are always present, values are always empty in
   GitOps output, operators fill them in via `sun secret set` or a secrets manager.

**Acceptance criteria:**

- `sun deploy --emit-to /tmp/out --dry-run` produces a Secret with all
  `stringData` values equal to `""`.
- `sun up --dry-run` still produces a Secret with the dev default `POSTGRES_URL`
  value (local mode is unchanged).
- The YAML comment block listing keys appears above `stringData` in GitOps output.
- `docs/deployment/self-hosted-substrate-contract.md` is updated.
