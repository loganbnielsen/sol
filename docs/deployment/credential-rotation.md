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
sol secret set --target prod/aws/us-east-1 DATABASE_URL
```

`sol secret set` is therefore both the create path and the rotation path, and it is
the **only** Sol CLI path that writes a secret value. The previous value is revoked
by updating the same object in place (there is no second copy to leave behind), so
no secret value appears in a plan, release record, or conformance bundle —
DEC-026 §7's invariant.

### Ordinary deploy and rollback never write a secret value

An ordinary `sol deploy`, `sol up` or `sol rollback` delivers secret *references*
only. It renders no Secret object, reads no value from the deploying process's
environment, and never mutates a Secret. Before it applies a workload it verifies
that the live `<svc>-secrets` object exists and carries every required non-empty
key — the unit's declared `[infra.env] secrets` keys plus the platform defaults
`POSTGRES_URL` and `SOL_API_KEY` — and that the workspace runtime Secret
`sol-secrets` carries the defaults. If any is absent or blank, the operation stops
before applying anything and names the keys to set.

That division is what makes a rotation durable: a later deploy cannot revert it to
whatever the deploying shell happened to hold, and it cannot blank a key an earlier
deploy never had. `sol secret set` also creates the target namespace when it is
missing, so it can bootstrap a fresh cluster before the first deploy; the workflow
is `sol secret set <KEY> ...` for each required key, then deploy.

### When something else owns the Secret

Step 1 is only a rotation if Sol is the authority for the object it patches. In a
deployment that delivers secrets through the External Secrets Operator, an
`ExternalSecret` owns each `<svc>-secrets` object and reconciles it from a
provider-side store; a direct write would be reported as applied and then
silently restored on the operator's next reconcile, and `sol secret delete`
loses the same race.

`sol secret set` and `sol secret delete` therefore inspect the live Secrets in
every namespace the operation selects, before changing anything or restarting any
workload. If any selected Secret is an `ExternalSecret`'s target, the whole
operation is refused — it names the managed target and the namespace, and points
at the provider store the `ExternalSecret` reads from. Nothing is written and no
workload is restarted, so a mixed selection cannot half-apply.

To rotate such a value, change it in the provider store and let the operator
reconcile; if you deliberately want Sol to own the Secret instead, remove that
`ExternalSecret`'s ownership of it first. Kubernetes-live Secrets that no
operator owns remain directly rotatable through `sol secret set`.

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
