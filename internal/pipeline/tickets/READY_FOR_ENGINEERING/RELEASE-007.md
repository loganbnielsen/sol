---
id: RELEASE-007
type: release
severity: high
source: AWS/GCP live qualification boundary audit 2026-10-05
title: Require real AWS and GCP qualification before publishing a release
---

**Depends on:** INFRA-116, INFRA-117, INFRA-118.

## Premise verified

`.github/workflows/release.yml` starts when a `v*` tag is pushed, builds the release bundle and
migration-runner image, then creates the GitHub release. It has no AWS/GCP qualification gate. The
live provider runners can exercise an installed bundle, and the alpha campaign requires the AWS
and GCP live matrices, but the tag currently makes the artifact public before those observations.
A run after publication cannot prevent a non-conformant artifact from being declared released.

## Remediation

Add a release-candidate stage that builds one immutable candidate from an exact source revision,
including the Sol bundle and its version-aligned migration-runner digest, but does not publish it
as a normal release. Run the provider-qualified scope from the candidate through the installed
public CLI on fresh AWS and GCP targets. Drive the required scenarios, observe provider and
Kubernetes state independently, destroy through Sol, and independently verify absence. Publish
that exact candidate only after the matrices' release-blocking rows pass; do not rebuild different
bytes at promotion time.

Use the matrices and alpha campaign to decide the rows and evidence required for each provider.
AWS production-profile claims and GCP provider-lifecycle claims are different scopes: GCP is not a
`production-single-region` qualification. A row that is explicitly blocked or excluded stays
visible with its reason and does not become a pass through omission. Provider-specific changes may
use a manually selected live run before merge when their risk warrants it; live cloud runs do not
become a per-PR default.

Preserve the live qualification cost rule: a provider run starts only with explicit authorization,
uses an isolated attempt and target, and does not wait for review while billable resources remain.
The release workflow must expose the candidate's exact revision, bundle version, runner digest,
row verdicts and teardown/absence evidence before publication.

## Acceptance criteria

- Pushing a final release tag cannot publish the bundle or runner before the required AWS and GCP
  candidate qualification has passed.
- Candidate and published artifacts are the same immutable bundle and runner digest, tied to one
  source revision; promotion does not rebuild or change them.
- Qualification runs use the installed candidate through supported Sol commands and preserve
  independent provider/Kubernetes observations and post-destroy absence verification.
- AWS and GCP use their current matrix-defined claims and exclusions; GCP is not marked as a
  production-profile pass, and blocked/not-run rows remain explicit.
- Live qualification is explicitly authorized and cost-gated. Ordinary PR CI does not provision
  billable cloud targets; a provider-specific pre-merge run remains an explicit opt-in.
- Release output or its attached record identifies the candidate revision, bundle version, runner
  digest, matrix rows and evidence records so the release verdict can be independently reviewed.
- Example impact: none; release and qualification workflow. Language-parity impact: none.
