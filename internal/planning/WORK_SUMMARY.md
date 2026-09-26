# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: GCP Attempt 11 — cert-manager qualified live, next blocker exposed (2026-09-26)

- Ran a fresh qualification target at `main @ 17afc4b2` (cluster `sol-qual-gcp-11`, its own state key). **cert-manager now works**: leader-election Role/RoleBinding in the `cert-manager` namespace, `successfully acquired lease cert-manager/cert-manager-controller`, no `kube-system` Warden denial, cainjector `"Updated object"` with an 896-byte `caBundle`, and the release completing in **2m13s** with its `startupapicheck` Job succeeded.
- **FND-0060 and FND-0010 are `QUALIFIED` live** (the latter on its own narrow claim: the check completed inside the budget it introduced). Nothing else is claimed — `Ready` was not reached.
- The next blocker is new: **FND-0061 / INFRA-089** — two `kubernetes_role_binding` resources in `platform_provisioner_rbac.tf` write the same Kubernetes name, so the targeted prerequisites step creates the object and the full `platform-apply` fails with `already exists` (201.6s). Deterministic, previously masked by the cert-manager failure, and left unfixed during the run.
- Supported destruction ran clean from the failed install: authority acquired → `platform-destroy ok (129.1s)` → released → substrate destroyed; both roots empty, provider inventory absent, durable prerequisites intact, no manual action.
