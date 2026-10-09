# GCP qualification matrix

The authoritative GCP claim inventory is
`gcp-production-single-region-v1-matrix.tsv`. Each row names the invariant, required evidence
class, falsifiable scenario, pass condition, and evidence expected from a conformant run.

This document defines only the result contract. Historical attempts and defect investigations
belong in their immutable records and Git history.

## Result contract

A run result is tab-separated:

```text
invariant_id	result	evidence_class	evidence_ref	note
```

A conformant complete run contains exactly one result for every matrix row and no unknown rows.
Every result is `PASS`, its evidence class exactly matches the row requirement, and
`evidence_ref` resolves to an artifact inside the run bundle. A failure, block, skip, unknown,
or unexecuted row makes the complete profile non-conformant; its evidence may still be useful.

Validate a result with:

```sh
internal/qualification/gcp/verify-matrix.sh path/to/results.tsv
```

The verifier fails closed on missing/duplicate/unknown rows, insufficient evidence classes,
missing references, and references that escape the bundle. Its mutation suite is
`test-verify-matrix.sh`.

## Evidence requirements

Behavioral rows require observation against the real GCP target and named execution identity.
Mechanism rows may use executable/rendered evidence, never documentation alone. Provider
documentation describes the expected provider contract; it cannot establish Sol behavior.

The bundle identifies the installed Sol release, target, GCP project/region, timestamp, execution
identity, deviations, and teardown verdict. Secrets are not evidence.

Application behavior is established by the reference scenario's transactions plus independent
provider/Kubernetes/database/broker observations required by the corresponding row. A successful
HTTP request does not implicitly pass infrastructure or messaging claims.

## Lifecycle and absence

Exercise cloud lifecycle through the installed `sol` release. The harness may capture provider
and Kubernetes observations but must not reproduce Terraform/Helm orchestration owned by Sol.

After teardown, query target-owned GCP resource classes through provider APIs. Every required read
must positively establish absence (or explicitly approved durable retention). Permission errors,
timeouts, malformed output, unavailable APIs, or unrecognized responses are `UNKNOWN` and fail
the absence verdict.

The durable state/DNS bootstrap is a prerequisite, not disposable target state; verify that target
teardown leaves required durable prerequisites intact.

## Running

`live-qual.sh` owns the current executable GCP run. Use a fresh `ATTEMPT` and evidence
directory, an installed release selected with `SOL_INSTALL`, the provider/project inputs named
by the script, and explicit operator authorization before creating billable resources. The host
needs `script` (util-linux) on `PATH`: the harness drives the whole-target deploy's first-run
installation offer through a pty, and a fresh account's deploy refuses rather than sets the
installation up without one.

The production profile's broker SASL credential is a pre-platform operator input. `sol deploy`
creates the `redpanda` namespace in its prerequisite stage, then checks the
`redpanda-users` Secret exists before the platform apply and stops naming it when absent
(`docs/deployment/production-bootstrap.md` § *Production Kafka transport (SASL_SSL)*). The
harness stands in for the operator: it generates a run-scoped `sol-workloads` SCRAM credential
(or uses `KAFKA_SASL_PASSWORD` when supplied), creates the Secret with the documented
`kubectl create secret generic redpanda-users -n redpanda` shape at that boundary, records that
it supplied the input without its value in `prerequisites.txt`, and re-runs `sol deploy`
to resume — the same ordered steps the bootstrap guide gives the operator. Credential creation
failing fails the phase rather than letting the platform apply proceed without the
prerequisite.

Run only the phases needed for the claims being exercised. On any blocker while billable
resources exist, preserve evidence, destroy through Sol, independently verify provider absence,
then stop.
