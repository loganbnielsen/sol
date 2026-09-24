# FND-0054 — `config_of_env` defaults unset Kafka, registry and admin addresses to localhost

- **Classification:** `DESIGN_GAP`
- **State:** `FIXED_UNQUALIFIED` (BUG-055, 2026-09-24: the three addresses are required, callers state them; tests + mutation check)
- **First identified:** 2026-09-24, correctness audit pass 2
- **Last verified:** 2026-09-24 (`origin/main @ fd5c7e0c`)
- **Derived ticket:** `BUG-055`
- **Invariant:** *"Dev mirrors prod exactly … if there's a divergence between dev and
  prod addressing or configuration, that divergence is a bug"* (AGENTS.md), and
  SEC-007's rule that connection posture is stated, not defaulted.
- **Evidence class:** `STATIC`

## What is established

`Kafka_service_config.of_env`
(`framework/ocaml/kafka-eio-service/lib/kafka_service_config.ml:2-25`) uses
`localhost:9092`, `http://localhost:8081` and `http://localhost:9644` when
`KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL` or `REDPANDA_ADMIN_URL` is unset. In a pod,
nothing listens there. A workload whose overlay or external-substrate config omits one
of them does not fail at startup: `register` fails against localhost with a connection
error, or the consumer polls a broker that is not there. The resulting error names
localhost, not the missing variable.

Sol-rendered manifests set all three (`default_cluster_env`), so the gap shows up on
the paths Sol does not render: GitOps overlays, `[infra.env] config` overrides for an
external Kafka, and hand-written manifests.

## Impact

Low. The failure is loud, but it is misattributed: it points at the network, not the
configuration.

## Remedy shape

Make the three variables required, with an `Error` naming each missing one, as SEC-007
did for `KAFKA_SECURITY_PROTOCOL`. `sol local run` and the documented local commands
set them.
