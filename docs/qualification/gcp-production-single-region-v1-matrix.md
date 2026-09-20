# Executable GCP qualification matrix — `production-single-region/v1` (HARDEN-004)

This is the GCP realization of the provider-neutral invariants in
`internal/pipeline/audits/invariants/PROVIDER-NEUTRAL-INVARIANTS.md`. The
authoritative row inventory is the adjacent
`gcp-production-single-region-v1-matrix.tsv`; this document defines how a run
turns those rows into a falsifiable result.

The matrix is a contract, not evidence that GCP passes it. Current observations
remain in `gcp-bootstrap-inventory.md` and the audit ledger. In particular,
platform `Ready` has not been reached, the authority defect tracked by
INFRA-045 remains open, and public TLS remains blocked. A future run must not
pre-fill those rows from this document.

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
