---
id: AUDIT-POST-007
type: audit-finding
severity: low
source: internal/pipeline/audits/2026-09-25_cloud_lifecycle_post_audit.md
---

`sol_cli_credentials` is AWS-specific behind a provider-neutral name

**Depends on:** None.

**Related:** INFRA-039, REFAC-096, AUDIT-POST-001

## Problem

`cli/sol/lib/sol_cli_credentials.ml` is entirely AWS:

- `aws configure export-credentials --format env` (`:50-64`);
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` (`:52-72`, `:85-95`);
- `aws sts get-caller-identity --query Arn` (`:75-81`);
- the failure message is written around AWS SSO and `aws sso login` (`:102+`).

Its only product caller is `cli/sol/lib/sol_cli_aws_cluster.ml:685`. The actual generic selection
point is `Sol_cli_provider_registry.credentials`, and GCP's credentials live in
`Sol_cli_gcp_cluster.ml`.

## Root cause

INFRA-039 added credential re-resolution for the AWS path and named the module after the concept
rather than the provider, before the provider/registry split (REFAC-095/096) made the ownership
question concrete. Nothing generic consumes it, so the name is the only thing that is wrong.

## Impact

A reader looking for "the credentials layer" finds a module with a generic name that is 100 % AWS,
while the dispatch is elsewhere. No behavioural defect; it is boundary hygiene — the same class the
program removed for larger components.

## Remediation

Make the name match the owner. Prefer a rename to `sol_cli_aws_credentials` unless folding the code
into `Sol_cli_aws_cluster` is materially simpler without making that module unwieldy.

- Rename the module and its `cli/sol/lib/dune` entry; update the single call site.
- Update any test that names it.
- Do **not** create a matching empty `gcp_credentials` abstraction for symmetry: GCP's credential
  path stays where it is.
- Do not change credential behaviour: per-operation re-resolution, the reported principal, and the
  fail-closed message stay as they are.
- `Sol_cli_provider_registry.credentials` remains the generic selection point.

## Acceptance criteria

- No `Sol_cli_credentials` module or reference remains (`rg -n 'Sol_cli_credentials' cli/` returns
  nothing).
- AWS credential behaviour unchanged; the AWS cluster's credential tests (or the harness scenarios
  that exercise credential failure) stay green.
- The provider registry is still the only generic credentials selection point.
- Build and `dune test cli/sol/test/` green.

## Completion notes (required)

- Problem / root cause / change / executable evidence / canonical merge SHA.
- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
