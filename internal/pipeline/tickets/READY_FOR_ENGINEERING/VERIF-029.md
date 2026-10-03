---
id: VERIF-029
type: verification
severity: medium
title: "GCP live-qual harness captures the VERIF-021 / VERIF-022 mechanism facts (read-only)"
source: internal/qualification/ALPHA_CAMPAIGN.md §7.3 — the GCP cells of VERIF-021 and VERIF-022 need their mechanism facts captured before the operator-gated run
---

**Depends on:** None.

**Related:** VERIF-021, VERIF-022, HARDEN-008, DEC-029, DEC-063,
`internal/qualification/gcp/live-qual.sh`, `internal/qualification/gcp/gcp-production-single-region-v1-matrix.md`.

`VERIF-021` (managed secret projection) and `VERIF-022` (projected ServiceAccount
tokens) are operator-gated live runs. Their GCP cells build on mechanism facts the
current harness does not capture — whether the GKE Secret Manager add-on is enabled and
at what rotation interval, which principals hold Secret Manager policy on the project's
`sol-` secrets, the cluster's OIDC issuer discovery document, and whether any deployed
pod renders a projected `serviceAccountToken` volume. This ticket lands that capture so
the live run is evidence collection rather than instrument building.

## Scope

- `live-qual.sh` gains an `identity` phase that writes `identity/identity.tsv` into the
  run bundle: the GKE Secret Manager add-on state and its rotation interval, the Secret
  Manager IAM policies on the project's `sol-` secrets, the cluster OIDC issuer discovery
  document, and the rendered projected `serviceAccountToken` volumes.
- `test-live-qual.sh` gains offline stubs and assertions for the capture, including that
  a failed cluster describe, secret list, secret policy read, pod list or non-200 issuer
  read is `UNKNOWN` — never `ABSENT` and never a pass.

## Non-goals

- Not the live run (`VERIF-021`, `VERIF-022`, `HARDEN-008`), and not the behavioural
  probes. The phase records mechanism facts only; a mechanism fact is a prerequisite, not
  a verdict on the row.

## Acceptance criteria

- `bash internal/qualification/gcp/test-live-qual.sh` passes.
- An unreadable cluster/secret/pod/OIDC read is recorded `UNKNOWN`, never `ABSENT`.
- Demo/example: not applicable — qualification tooling, with no app-author-facing surface.
- Language parity: not applicable — no application-facing contract change.
