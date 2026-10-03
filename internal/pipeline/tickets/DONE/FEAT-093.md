---
id: FEAT-093
type: feature
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Production Kafka transport: Redpanda TLS + SASL, the workload projection, and registry/admin HTTPS

**Depends on:** None.

**Finding:** FND-0039 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-10-03** at `origin/main @ e2079ae8`: no Sol path enabled
Redpanda TLS or SASL. `platform/shared/components.json`'s `redpanda.common.tls.enabled`
was `false`, the `durable` layer carried no `auth`, and the rendered workload env
declared `KAFKA_SECURITY_PROTOCOL=plaintext` with no `KAFKA_SSL_*`/`KAFKA_SASL_*`
(`cli/lib/workspace/sol_cli_manifest_yaml.ml`, the only render site). Positive
control: the same search over `platform/` matches the `tls.enabled` guard key the
drift check knows about.

## Problem

Production-profile Kafka, schema registry and admin API were plaintext and
unauthenticated (FND-0039). SEC-007 declared that posture instead of hiding it,
but it was plaintext in every profile.

## Decision (2026-10-03) — require SASL_SSL now

Operator decision: **Require SASL_SSL now.** The production profile establishes
authenticated and encrypted Kafka transport rather than knowingly qualifying
plaintext and replacing it later. Local/dev ergonomics stay plaintext.

## Remediation

Enable Redpanda TLS (cert-manager-issued) and SASL in the production component
profile; project `KAFKA_SECURITY_PROTOCOL=sasl_ssl`, the CA and the SASL
credential into workloads; serve the schema registry and admin API over HTTPS.

## What landed (2026-10-03)

**Platform.** The `durable` layer of `redpanda` in
`platform/shared/components.json` enables `tls`, SASL (`SCRAM-SHA-256`,
`secretRef: redpanda-users`) and schema-registry TLS, so the chart has
cert-manager issue an in-cluster CA plus the broker, schema-registry and admin
leaf certificates. A new `platform_profile` variable on
`platform/cloud/modules/platform` selects the component layer; Sol sets it to
`durable` from the target's `production-single-region` profile, independent of
`observability_backend`. That decoupling matters: the component layer used to be
driven only by `observability_backend`, so a production target with external
telemetry would have kept plaintext Redpanda. The variable is mirrored in both
provider roots and passed to the module.

**Workloads.** A production plan injects the declared posture into each
service's own `config` (`Sol_cli_manifest.production_kafka_config`):
`KAFKA_SECURITY_PROTOCOL=sasl_ssl`, the HTTPS schema-registry/admin URLs,
`KAFKA_SASL_MECHANISM=SCRAM-SHA-256`, `KAFKA_SASL_USERNAME=sol-workloads` and
`KAFKA_SSL_CA_LOCATION`. Because it lives in `spec.config`, it travels in the
release record, so a rollback reproduces the posture instead of silently falling
back to plaintext. The renderer derives the mount and the required secret keys
from the declared protocol: production workloads mount the workload Secret's
`KAFKA_SSL_CA_CERT` at `/etc/sol/kafka/ca.crt`, and an ordinary deploy fails
closed unless that Secret also carries `KAFKA_SASL_PASSWORD` and
`KAFKA_SSL_CA_CERT`. The in-cluster `contract/run` Job gets the same posture and
CA. Local and the dev shapes stay plaintext and declare it.

**Operator contract.** Sol never generates or stores the credential. The
operator creates the broker's `redpanda-users` Secret, then sets the two
workload Secret keys with `sol secret set`;
`docs/deployment/production-bootstrap.md` records the procedure, and
`docs/reference/substrate.md`, `docs/architecture/PRODUCT_ARCHITECTURE.md` and
`examples/pluto/README.md` state the new posture.

## Acceptance criteria

- A production-profile target's workloads connect over SASL_SSL (HARDEN
  behavioural evidence). *The in-repo transport is complete; the live
  behavioural evidence is the S5 AWS run (HARDEN-007), which this ticket
  unblocks. Here, unit tests assert the rendered SASL_SSL manifest and the
  chart's durable values were rendered with `helm template 26.1.11` to confirm
  Kafka/schema-registry/admin TLS and SASL.*
- Local remains plaintext and is declared as such. *Kept; asserted by tests.*

## Checks run

- `dune build cli/bin/main.exe` and `dune build cli/test/` clean.
- `dune build @cli/test/inline/runtest`: every suite passes except two
  `Test_scaffold` cases that need the `sol-*` framework libraries installed in
  the opam switch (environmental, unrelated to this change); the new
  `test_manifest_render` and `test_profile` assertions pass.
- `python3 internal/ci/check_platform_component_drift.py` and
  `check_production_infra.py` clean; both mutation suites pass.
- `helm template` of chart `26.1.11` with the real `common` + `durable` values
  renders `enable_sasl`, SASL on 9093, and TLS on the Kafka, schema-registry and
  admin listeners, plus cert-manager `Certificate`/`Issuer` objects.

## Demo/example coverage

`examples/pluto/README.md`'s production-profile section now gives the broker and
workload credential steps. The local example path is unchanged because local
stays plaintext.

## Language parity (DEC-022)

No application-facing contract change: both languages already read the same
`KAFKA_SECURITY_PROTOCOL`/`KAFKA_SSL_*`/`KAFKA_SASL_*` names — OCaml
`Kafka_service.config_of_env`, TypeScript `kafkaConfigFromEnv` (FEAT-097). This
ticket only makes Sol render and require them.

## Remaining limitation

The live qualification that a workload actually connects over SASL_SSL on a real
target is S5's HARDEN-007 run, which this ticket unblocks; it is not part of this
in-repo change.
