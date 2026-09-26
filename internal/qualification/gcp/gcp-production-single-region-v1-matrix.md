# Executable GCP qualification matrix — `production-single-region/v1` (HARDEN-004)

This is the GCP realization of the provider-neutral invariants in
`internal/pipeline/audits/invariants/PROVIDER-NEUTRAL-INVARIANTS.md`. The
authoritative row inventory is the adjacent
`gcp-production-single-region-v1-matrix.tsv`; this document defines how a run
turns those rows into a falsifiable result.

The matrix is a contract, not evidence that GCP passes it. Current observations
remain in `gcp-bootstrap-inventory.md` and the audit ledger. In particular,
platform `Ready` has not been reached, the authority finding FND-0001 is
implemented (#376) but unqualified against a live cluster, and public TLS remains
blocked. A future run must not pre-fill those rows from this document.

## Result contract

A run writes a tab-separated results file with exactly this header:

```text
invariant_id	result	evidence_class	evidence_ref	note
```

There must be exactly one result for every invariant row and no unknown rows.
`result` must be `PASS`; a failure, block, skip, or unexecuted row makes the
complete GCP profile non-conformant. `evidence_class` must equal the row's
required class (`MECHANISM` or `BEHAVIORAL`), and `evidence_ref` must be a
relative path that resolves inside the results file's bundle directory. A note
may be concise, but the field must be present so the format remains stable.

This intentionally makes incomplete runs fail. Their artifacts are still
valuable and should be retained as attempts, but they are not conformant runs.
Blocked capabilities such as public TLS are recorded in the attempt and remain
unqualified; they cannot be converted into a passing provider-neutral
substrate claim by omission.

Verify a result with:

```sh
internal/qualification/gcp/verify-matrix.sh path/to/results.tsv
```

The verifier fails on a missing, duplicate, unknown, non-passing, weakly
evidenced, evidence-less, or missing-artifact row. Its mutation test demonstrates
the failing-row, missing-row, insufficient-evidence, and missing-artifact
directions:

```sh
internal/qualification/gcp/test-verify-matrix.sh
```

## Run identity and evidence bundle

The results file is only one bundle member. INV-EVID-4 requires the bundle to
identify the target, provider/project/region, Sol revision, profile version,
timestamp, operator/reconciliation identity, and deviations. Evidence paths
must resolve within that bundle. Secrets are never bundle evidence.

Rows requiring `BEHAVIORAL` evidence need observations from the named identity
against the disposable target. Rows requiring `MECHANISM` evidence may use an
offline verifier or inspected execution artifact, but not documentation alone.
Provider documentation establishes expected provider behavior; it does not
establish that Sol exhibited it.

## Relationship to the AWS matrix

The AWS matrix groups product scenarios into sections A–J. This GCP matrix is
keyed to stable provider-neutral invariant IDs instead of copying AWS
mechanisms. Its scenarios use GCP impersonation, GKE authorization, Cloud SQL,
Artifact Registry, and provider-side GCP absence queries. This preserves the
semantic contract while making provider differences observable.

## Before the next attempt (Attempt 5)

Attempt 5 is the first run that can reach `Ready` on GCP, and the first that must
produce evidence for three findings at once. Two captures that earlier attempts
missed decide whether the run is diagnosable.

### The narrowed provisioner role still reaches the cluster (FND-0001)

`INFRA-045` replaced the project-level `roles/container.developer` grant with a
custom role holding only `container.clusters.get`, `.list`, `.getCredentials` and
`.connect`. That change closes a hole and opens a live risk in the other
direction: if the role is *insufficient*, the platform stage fails at credential
retrieval or connection rather than at a chart. Record the effective IAM binding
and the precise failure if one appears, so a cluster-access failure is not
misread as a cert-manager or chart problem. A Kubernetes-object operation
attempted as the provisioner must be **denied**; that denial is FND-0001's
behavioural half.

### Why the cert-manager post-install check fails (FND-0010)

Attempts 3 and 4 stopped at `helm_release.cert_manager`'s post-install
`startupapicheck` while cert-manager itself was healthy. The check performs a
dry-run create of a `v1` Certificate in the `cert-manager` namespace, which forces
the API server to call the cert-manager **validating webhook** (the chart's
"v1alpha2 / conversion webhook" comment is stale; the CRD serves only `v1`).

Before the platform stage gives up, capture:

- `kubectl -n cert-manager logs job/cert-manager-startupapicheck --all-containers`
  — the container's own output. A webhook-call failure or `context deadline
  exceeded` confirms the GKE control-plane → webhook-pod-port hypothesis;
  `x509: certificate signed by unknown authority` instead means the webhook CA
  bundle is not injected, which is a different cause with a different fix.
- `kubectl -n cert-manager get events --sort-by=.lastTimestamp` and
  `kubectl -n cert-manager describe job cert-manager-startupapicheck`.
- `kubectl -n cert-manager get svc cert-manager-webhook -o jsonpath='{.spec.ports[*].targetPort}'`
  (expect `10250`).
- `gcloud compute firewall-rules list --filter="name~<cluster>"` beside the
  cluster's `masterIpv4CidrBlock`.

**Attempt 8 (2026-09-25) answered this, and it is the second branch.** The check's
output was `x509: certificate signed by unknown authority`, the webhook Service had live
endpoints (`10.1.0.78:10250`, `targetPort: https`), and the webhook configuration carried
no injected `caBundle` at capture time — so the cause is the CA bundle, not reachability,
and **no `google_compute_firewall` is warranted**. Evidence:
`internal/qualification/records/2026-09-25-gcp-attempt8.md`.

If reachability is confirmed, the fix is a `google_compute_firewall` allowing the
master CIDR to the webhook's **pod** port, and FND-0010 becomes a `VERIFIED_DEFECT`
with a ticket. Disabling `startupapicheck` is not a fix: it discards the only
signal that the webhook is reachable, which certificate issuance depends on.

### What the run must not do

- Do not pre-fill any row from this document or from `gcp-bootstrap-inventory.md`.
- Do not attribute the stop to `roles/container.developer` (it is gone) or to the
  chart (cert-manager's own pods were healthy).
- Record FND-0007 (external TLS) as blocked, not passed, while no hostname is
  delegated to the target.

## Case coverage so far (2026-09-26)

This document is still a contract, not evidence; the rows below are the cases actually observed, each
from the run named. Nothing else is pre-filled from them.

| Row | Case | State |
|---|---|---|
| `INV-DESTROY-1` | destroy from **failed `PlatformInstalling`** | **satisfied live** (2026-09-26, `qual9/gcp/us-central1`: authority reacquired and removed, platform teardown ran, both roots empty). See `2026-09-26-gcp-fnd0058-live-qualification.md` |
| `INV-DESTROY-1` | destroy from `CloudBootstrap`, from `Ready`, and from interrupted destruction | **not observed** |
| `INV-DESTROY-4` | both destroys return success, then every class queried | **partially**: the failed-install case now ends with both roots empty and an independent class-by-class sweep; the `Ready` case is not observed |
| `INV-RET-1` | `retention: none` | observed (2026-09-26 and Attempt 8) |
| `INV-AUTH-3` | window closed on the install-failure path | observed (2026-09-26) |
| `INV-SUBSTRATE-*`, `INV-IDENT-1` | a running platform | **not reached** — no attempt has installed the platform to `Ready` |
