# Production workload credentials and rotation (SEC-004)

Two guarantees for `production-single-region`:

1. **No ambient Kubernetes credential.** A workload receives no mounted
   service-account token unless a declared capability requires one.
2. **Supported runtime credentials rotate without undefined behavior.** A
   rotated database/API credential is used by the workload, the old value is
   revoked, and the workload returns to healthy state — without hand-editing
   generated manifests.

## No ambient token

Every Sol-rendered workload uses a per-workload ServiceAccount, and the renderer
sets `automountServiceAccountToken: false` on it
(`Sol_cli_manifest_yaml.service_account_doc`). Because the token is projected
into the pod only when the ServiceAccount permits it, a default workload pod has
no Kubernetes API token and no in-cluster API access.

This is a Sol-owned property of the rendered plan, so the profile preflight's
`credential_posture` guarantee is established for every plan. Maturity A ships
**no** opt-back-in capability: exposing a "this workload may call the Kubernetes
API" knob without a meaningful least-privilege permission model would be worse
than not offering it, so it is deferred until a concrete workload needs one.
(Workload identity federation, service-to-service authorization, admission
policy and multi-team RBAC remain out of maturity A per DEC-026 §7.)

## Rotation: secret update, then a verified restart

Workloads receive secrets as environment variables (`envFrom.secretRef`). A
running pod never observes a changed environment variable, so rotation is
necessarily:

1. **update** — `sol secret set` patches the shared `sol-secrets` object and each
   per-workload `<svc>-secrets` object in the namespace;
2. **restart** — Sol restarts every live Deployment (and Rollout, when Argo
   Rollouts is installed) in that namespace, because the env-var contract means
   only a new process picks up the new value;
3. **verify** — Sol waits for `kubectl rollout status --timeout=120s` on each. A
   workload that never becomes healthy fails the whole operation, so "rotation
   completed" is a claim Sol can back rather than assume.

```bash
sol secret set --env prod --target prod/aws/us-east-1 DATABASE_URL
```

`sol secret set` is therefore both the create path and the rotation path. The
previous value is revoked by updating the same object in place (there is no
second copy to leave behind), so no secret value appears in a plan, release
record, or conformance bundle — DEC-026 §7's invariant.

The 120-second bound is a maturity-A default; a target whose workloads legitimately
take longer should be treated as outside the profile rather than silently given
an unbounded wait. Delivered restarts are exercised by HARDEN-002 against a
disposable credential: rotate → observe the new value in use → confirm the old
value no longer authenticates → confirm the workload is healthy.

## What is deliberately out of scope

- **A Kubernetes-API-access capability.** No maturity-A workload may have
  ambient API access; adding a narrow Role/RoleBinding grant needs a concrete
  capability and a least-privilege permission set first.
- **File-mounted secret refresh.** The env-var contract is kept, so kubelet's
  file-refresh behavior is not relied on.
- **Versioned secret names.** Names churn and leak history; in-place update plus
  restart is simpler and auditable.
- **Build-time secrets** (FEAT-053) — a different lifecycle, not a substitute
  for runtime rotation.
