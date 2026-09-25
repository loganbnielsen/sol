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

## Completion notes (2026-09-25)

**Problem.** `cli/sol/lib/sol_cli_credentials.ml` (+ `.mli`) was entirely AWS — `aws configure
export-credentials --format env`, `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`,
`aws sts get-caller-identity`, and a failure message written around SSO and `aws sso login` — behind
a provider-neutral name. Its only product caller was `Sol_cli_aws_cluster`.

**Root cause.** INFRA-039 added AWS credential re-resolution and named the module after the concept
before the provider/registry split (REFAC-095/096) made the ownership question concrete. Nothing
generic consumed it, so only the name was wrong.

**Change.** Renamed to `sol_cli_aws_credentials` (`.ml` and `.mli`) and placed with the other AWS
modules in `cli/sol/lib/dune`; the three call sites in `Sol_cli_aws_cluster` updated; the module
header now says it is the AWS mechanism and names the generic selection point
(`Sol_cli_provider_registry.credentials`). `PROVIDER-NEUTRAL-INVARIANTS.md`'s reference to
`sol_cli_credentials.resolve` updated. No `gcp_credentials` module was created for symmetry — GCP's
credential path stays in `Sol_cli_gcp_cluster`.

**Executable evidence.**
- `rg -n 'Sol_cli_credentials|sol_cli_credentials' cli/ internal/ docs/ examples/` returns nothing
  outside the two records that describe the rename.
- `dune build` green; `dune test cli/sol/test/ --force` green, including the harness scenarios that
  exercise credential resolution and its failure path.
- The provider registry is still the only generic credentials selection point
  (`Sol_cli_provider_registry.credentials`), unchanged by this ticket.

**Canonical merge SHA.** The squash commit that moved this ticket to `DONE/`; recover it with
`git log --oneline -1 -- internal/pipeline/tickets/DONE/AUDIT-POST-007.md`.

- Demo/example: not applicable (cloud lifecycle internals).
- Language parity (DEC-022): no application-facing impact.
