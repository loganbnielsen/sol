# GCP qualification Attempt 20 (2026-09-28) — the application row reached the platform, then stopped on a harness gap

## Summary

| | |
|---|---|
| revision | `621b3f9d` (`DEC-056`: `Ready` covers the platform's declared certificates) |
| target | fresh `qual20/gcp/us-central1`, cluster `sol-qual-gcp-20`, 4 × e2-standard-4, `cluster_issuer: letsencrypt-staging` |
| **what the run established** | the **strengthened `Ready` is observed**: `lifecycle phase: Ready` was reported with `argocd-tls` and `grafana-tls` both `True` — the gate now requires them |
| where it stopped | the application phase, at `sol migrate apply`: `required secret env var(s) not set: POSTGRES_URL` |
| cause | **qualification machinery**, not the product: the harness never supplied the database URL the documented operator step provides |
| fix | the harness reads the cluster root's `postgres_url` output and exports it, recording it redacted (next PR) |
| specimen | converged with the supported destroy; the substrate was not repaired and re-used |

## What the run established before it stopped

Substrate, platform install and the strengthened readiness contract, on a fresh target:

- `terraform-apply ok (811.3s)`, `platform-prerequisites-apply ok (51.4s)`, `platform-apply ok (179.9s)`;
- **`lifecycle phase: Ready`**, and at that moment `kubectl get certificates -A` reported
  `argocd/argocd-tls True` and `monitoring/grafana-tls True` — the `DEC-056` contract doing what it
  promises rather than a run that happened to be lucky;
- delegation observed, 75 API-readiness samples.

The application phase then built and pushed both images (`docker build` from each service's own
Dockerfile, `docker push` into the target's Artifact Registry — the pushed manifests and their digests are
in the bundle) and failed on the next step.

## The failure, and why it is not a product defect

```text
error: required secret env var(s) not set: POSTGRES_URL. The workspace substrate (its runtime Secret)
cannot be established without them, and every workspace-scoped operation -- migrations included -- needs it.
```

`POSTGRES_URL` is the operator's to supply, and the product says so plainly
(`docs/deployment/production-bootstrap.md`): the provider root's `postgres_url` output "exists so an
operator can place the connection string in their secret store for the runtime Secret that workloads read
as `POSTGRES_URL`". `sol migrate apply` submits an **in-cluster Job** (`cli/bin/cmd_migrate.ml`), so the
value is needed only to build the Job's secret — the private Cloud SQL address is reached from inside the
cluster, not from the machine running the harness.

So the product behaved as designed and the harness was incomplete: it drove the platform but not the
secret hand-off the application path begins with. Supplying it is machinery, not policy, and it is now a
step of the app phase: read the output the product already publishes, export it for the two steps that
need it, and record it **redacted** so the evidence bundle never carries the password.

## Discipline note

The specimen was **not** repaired and continued. The application phase's first unexpected result was
captured with the bundle frozen (`/tmp/sol-gcp-qual-20`, including the pushed image digests, the deploy
attempt's absence, and the platform's certificate state), the harness defect was fixed offline with suite
coverage, and the target was converged with the supported destroy before the next specimen. That is the
sequence the qualification rules prescribe: a specimen that stops is converged, never patched.
