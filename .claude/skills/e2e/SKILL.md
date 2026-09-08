---
description: Use when running tests, verifying the full system end-to-end, or running the demo. Covers broker setup, unit tests, integration tests, and the demo sandbox. Do not run tests directly without invoking this skill.
---

# /e2e — Run E2E test matrix (includes /test and /demo workflows)

Ensures the local environment is consistent, spins up infrastructure, and runs the full validation matrix.

## Preferred: use the test runner

`platform/local/scripts/run_tests.sh` is the canonical way to run tests. It handles infrastructure setup, per-suite timeouts, and performance regression checks against `devtools/perf/perf_baseline.json`.

```bash
# Full matrix (all suites, infra auto-provisioned)
bash platform/local/scripts/run_tests.sh

# Specific suites only
bash platform/local/scripts/run_tests.sh unit kafka

# Skip infra setup if broker/loki/postgres are already running
bash platform/local/scripts/run_tests.sh --no-infra

# After an intentional performance change, update the baseline
bash platform/local/scripts/run_tests.sh --update-baseline
```

### Performance baseline management (`platform/local/scripts/perf.sh`)

```bash
bash platform/local/scripts/perf.sh status              # all suites: baseline, latest, drift
bash platform/local/scripts/perf.sh history [suite]     # full run history with regression markers
bash platform/local/scripts/perf.sh set-baseline [suite|all]  # mark latest run as new baseline
bash platform/local/scripts/perf.sh clear [suite|all]   # wipe history for a suite
```

### Git hook (runs unit tests automatically on every commit)

```bash
bash platform/local/scripts/install-hooks.sh   # one-time setup
# Skip once: SOL_SKIP_PERF_HOOK=1 git commit ...
```

If netcat checks fail: `sudo apt-get install -y netcat-openbsd`

## Manual suite commands (fallback / debugging)

Use these when you need to run a single suite directly without the full runner harness.

### Unit tests (no infrastructure)
```bash
eval $(opam env) && dune test framework/ 2>&1
```

### Kafka integration tests
```bash
bash platform/local/scripts/ensure-broker.sh
eval $(opam env) && KAFKA_BROKERS=localhost:9092 dune test framework/kafka-eio-service/ --force 2>&1
```

`obs-eio`/`obs-loki-eio`/`obs-prometheus-eio` no longer have a test suite in this repo —
they moved to standalone packages (`~/Code/obs-eio`, `~/Code/obs-loki-eio`,
`~/Code/obs-prometheus-eio`); run their tests there.

`pg-eio` (formerly `sol-storage`) likewise no longer has a test suite in this repo —
it moved to `~/Code/pg-eio`; run its tests there. Storage-touching code that stays in
Sol (the example apps) is covered by the e2e suite below instead.

### Venus reference workspace (primary demo)
Two-team showcase: payments/charge-svc → Kafka → comms/notify-worker → PostgreSQL, with Loki + Prometheus:
```bash
bash platform/local/scripts/ensure-broker.sh && bash platform/local/scripts/ensure-postgres.sh && bash platform/local/scripts/ensure-loki.sh && bash platform/local/scripts/ensure-grafana.sh
eval $(opam env) && KAFKA_BROKERS=localhost:9092 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev LOKI_URL=http://localhost:3100 dune exec examples/venus/bin/run.exe 2>&1
```

### Demo sandbox (legacy single-team demo)
```bash
bash platform/local/scripts/ensure-broker.sh && bash platform/local/scripts/ensure-postgres.sh
eval $(opam env) && KAFKA_BROKERS=localhost:9092 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev dune exec examples/local-demo/bin/demo.exe 2>&1
```

All backend env vars (`POSTGRES_URL`, `LOKI_URL`) are optional — both demo binaries degrade gracefully to stdout logs and skip DB if not set. Kafka is required.

## Visibility

After `ensure-grafana.sh` runs, logs are browsable at:
- **Grafana Explore** → http://localhost:3000/explore
- Select the **Loki** datasource and run a LogQL query, e.g. `{service="payments-worker"}`
- Live tests use service names like `loki-e2e-test-<timestamp>` — search `{service=~"loki-.*"}` to find them

## Infrastructure

| Service    | Script                                 | URL / connection                                         |
|------------|----------------------------------------|----------------------------------------------------------|
| Redpanda   | `platform/local/scripts/ensure-broker.sh`      | localhost:9092 (Kafka)                                   |
| Loki       | `platform/local/scripts/ensure-loki.sh`        | localhost:3100 (API)                                     |
| Grafana    | `platform/local/scripts/ensure-grafana.sh`     | localhost:3000 (UI)                                      |
| PostgreSQL | `platform/local/scripts/ensure-postgres.sh`    | `postgresql://postgres:dev@localhost:5432/sol_dev`       |

Redpanda, Loki, Grafana, and PostgreSQL all run as named Docker containers. Loki and Grafana share
the `sol-obs` Docker network so Grafana can reach Loki at `http://loki:3100`.

Storage integration tests require `POSTGRES_URL` to be set; without it they print `[skip]` and pass.

## Debugging

- **Unbound Eio modules** — Eio 1.3 requires `Eio_unix.Stdenv.base`; capture clocks via `env#clock : _ Eio.Time.clock`.
- **Consumer hang** — if offsets are at `Latest` and the consumer is stuck, reset with:
  ```bash
  docker exec redpanda rpk topic delete sol-demo && bash platform/local/scripts/ensure-broker.sh
  ```
- **Loki live tests skipped** — they require `LOKI_URL` to be set; run via the full matrix command above.
- **Grafana can't reach Loki** — verify both containers are on `sol-obs`: `docker network inspect sol-obs`
- **Verification targets** — `ffi_smoke` must print `"OK: all stubs passed"`; integration tests must log pass/fail counts.
