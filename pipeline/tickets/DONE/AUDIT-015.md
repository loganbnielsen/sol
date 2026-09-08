---
id: AUDIT-015
type: audit-finding
severity: high
source: project/audits/2026-06-10_audit.md
branch: AUDIT-015/postgres-url-secret
worktree: ../sun-AUDIT-015-postgres-url-secret
---

`POSTGRES_URL` With Embedded Password Flows Into ConfigMap

**Depends on:** None.

**Description:** `POSTGRES_URL` with the embedded password `dev` is in `default_cluster_env` in `sun_cli_manifest.ml`, which is written verbatim into the Kubernetes ConfigMap by `configmap_doc`. `secret_doc` was added as a fix but is never called from `render` or `render_spec` — it is dead code. The ConfigMap is stored unencrypted in etcd and is readable by any pod in the namespace via `envFrom: configMapRef`.

**Impact:** Any compromised pod or overly permissive RBAC policy exposes the database password in plaintext. Violates the "Credentials are never in ConfigMaps" invariant. The default password `dev` will be copy-pasted to staging/production by users who follow the scaffold without realising the credential is not production-ready and is in an insecure location.

**Remediation:** Move `POSTGRES_URL` from `default_cluster_env` to a separate secrets list. Wire `secret_doc` into `render` and `render_spec` so a `Secret` resource is emitted alongside the `ConfigMap`. The ConfigMap should carry only non-sensitive config (brokers, observability URLs). Remove `POSTGRES_URL` from the ConfigMap render path.

