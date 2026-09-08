# DOGFOOD-005: Customer-Cloud Deployment Contract
**Date:** 2026-06-11  
**Tester:** Claude Sonnet 4.6 (automated dogfood pass)  
**Branch:** DOGFOOD-005/customer-cloud-contract

---

## Environment

- OS: Linux 6.6.87.2-microsoft-standard-WSL2 (Ubuntu)
- k3d `sun-local` cluster; dogfood workspace at `/tmp/dogfood-test/dogfood_acme`
- `sun` binary: `~/.local/bin/sun`

---

## Steps Executed

| Step | Command | Result |
|------|---------|--------|
| 1 | `sun deploy --dry-run` | Exit 0; manifests rendered correctly ✓ |
| 2 | `sun deploy --emit-plan-to -` | Prints JSON plan then executes deploy (see F1) |
| 3 | `sun deploy --emit-to /tmp/gitops-out` | Writes 2 YAML files; prints ArgoCD hint ✓ |
| 4 | Inspect plan JSON | `topics: []`, `migrations: []` (see F2) |
| 5 | Inspect GitOps YAML | Secrets in `stringData` plain text (see F3) |
| 6 | Review `platform/infra/` | Three-tier structure clear; documented inline ✓ |

---

## Findings

### F1 — MINOR: `--emit-plan-to` does not prevent deployment execution

`sun deploy --emit-plan-to -` writes the plan JSON to stdout and then
proceeds to execute the full deployment. The flag name implies "plan output"
but does not imply "dry run." However, users who reach for `--emit-plan-to`
intending to inspect before deploying will be surprised by the execution.

The combination `--emit-plan-to FILE --dry-run` correctly prevents execution
and writes the plan.

**Suggested improvement:** Document explicitly in the help text that
`--emit-plan-to` does not stop execution; combine with `--dry-run` to preview
only. Or rename to `--plan-file` to avoid the "to" implying one-way output.

### F2 — MODERATE: Deployment plan omits Kafka topics and pending migrations

The deployment plan JSON (`--emit-plan-to`) shows:
```json
"topics": [],
"migrations": []
```

The dogfood workspace uses topic `dogfood_acme-payments-charges` (declared in
`Charged.topic_name`) and has a pending migration at `db/migrations/`. Neither
appears in the plan.

For the customer-cloud contract, this means: an operator reading the plan
cannot determine which Kafka topics the deploy will touch or whether migrations
need to run. The plan is incomplete for change-management review.

**Suggested improvement:** Scan `events/` for `topic_name` values and
`db/migrations/` for pending migration files, and include them in the plan.

### F3 — HIGH: GitOps YAML includes secrets in plain text `stringData`

`sun deploy --emit-to` generates YAML files that include:
```yaml
kind: Secret
stringData:
  POSTGRES_URL: "postgresql://postgres:secret@..."
  STRIPE_KEY: "sk_test_abc"
```

Plain-text secrets in a GitOps repository are a security vulnerability. If the
repository is shared (e.g., an ArgoCD monorepo), all secret values are visible
to anyone with read access. The file is also committed to git history.

**Suggested improvement:**
- Document clearly in `--emit-to` output and help text that the generated
  Secrets contain plain-text values and must not be committed to a shared repo.
- Provide guidance on replacing `stringData` with ExternalSecrets or
  Sealed Secrets references before committing.
- Long-term: `sun deploy --emit-to` should emit ExternalSecrets stubs
  referencing a configured secrets backend, not raw values.

---

## Platform/Infra Structure Assessment

```
platform/infra/
  base/    — cluster-agnostic; installs cert-manager, nginx, ArgoCD,
             Redpanda, PostgreSQL, Loki, Prometheus onto any kubeconfig
  aws/     — AWS cluster provisioning (EKS, VPC, node groups)
  gcp/     — GCP cluster provisioning (GKE, VPC, node groups)
  argocd/  — ArgoCD application definitions
  ci/      — CI/CD pipeline helpers
```

### Three Ownership Lanes

| Lane | Scope | Owner | Primary interface |
|------|-------|-------|-------------------|
| **Cluster** | AWS/GCP infra, networking, node pools | Customer DevOps | `platform/infra/aws/` or `platform/infra/gcp/` |
| **Platform** | Kafka, PostgreSQL, TLS, Ingress, observability | Sun platform bootstrap | `platform/infra/base/` |
| **App** | Services, workers, migrations, secrets | Developer | `sun up` / `sun deploy` |

This is a clean separation. Terraform is NOT the primary app interface — it
is substrate implementation/escape hatch. App developers never need to touch
Terraform; they work only via `sun up` and `sun deploy`.

The `base/` module installs the same set of platform services regardless of
cloud provider, which correctly implements the "dev mirrors prod" promise.

---

## What Passed

- `sun deploy --dry-run` renders complete Kubernetes manifests without applying.
- `sun deploy --emit-to` writes one YAML file per service (namespace-prefixed)
  and prints an ArgoCD commit-and-push instruction. Output is deterministic.
- Platform/infra three-tier structure is self-consistent and well-commented.
- `environment.mode: "customer_cloud"` in the plan JSON correctly identifies
  the deployment target mode.
- The `base/` module documents which Helm charts it installs and their purpose.
- ArgoCD is included as the GitOps continuous delivery layer.

---

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| Customer-cloud docs explain the three ownership lanes | **Pass** (table above; inline Terraform comments) |
| Generated deployment plans are complete enough to reason about | **Partial** (F2 — topics and migrations missing) |
| Terraform is documented as substrate implementation/escape hatch | **Pass** (CLAUDE.md, base/main.tf header comments) |
