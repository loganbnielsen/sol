# Observability qualification workstream

This directory qualifies one question:

> **When something goes wrong in a Sol workspace, do the observability and
> diagnostic surfaces Sol claims to provide actually detect it, let an operator
> investigate it, name its cause, and recover — with evidence that could have
> failed?**

It is the observability slice of the qualification ledger's rule (see
`../README.md`): standing goals are not tickets, each run is a record, defects
become findings and ordinary tickets, and the classes of evidence are not
interchangeable.

## Evidence classes

The ledger's operating rule 7 defines the classes. This workstream uses them
literally, and never promotes one to another:

| Class | What it is | What it can establish |
|---|---|---|
| **MODELED** | A written model of the behaviour: a rendered template, a Terraform/Helm value, a mock, or a stub written from the implementation. | What the configuration *says*, nothing about what a running system *does*. |
| **MECHANISM** | A real component exercised in isolation, or a static property verified against the artifact that owns it (e.g. a chart default read from the chart). | That the mechanism exists and is wired; not that the end-to-end effect occurs. |
| **LOCAL** | Observed on this host against real backends (Redpanda, native Loki/Prometheus/Tempo/Pushgateway) with the real `sol` binary and the real framework runtime. | Behaviour of the framework and CLI, on one host, without Kubernetes. |
| **LIVE** | Observed on a real deployed cluster / cloud target, as an identified principal. | The production contract. **None is claimed in this workstream yet.** |

A row is qualified only at the class its claim needs. `sol status` reaching a
local Loki is LOCAL; the same claim on a deployed target (where the backend is
resolved from a target file and reached through the cluster) is LIVE and is not
inherited from the local observation. "Unqualified" means "not yet established by
evidence that could have failed" — never "false".

## The environment this workstream ran in (2026-10-02)

- Revision: `main @ 2a2c5a7c`.
- Redpanda, native, `localhost:9092` / schema registry `:8081` / admin `:9644`.
- Loki 3.0.0, Prometheus 2.53.0, Tempo 2.5.0, Pushgateway 1.9.0, native
  binaries started on this host (the repository's `ensure-*.sh` scripts run these
  in Docker, and Docker is unavailable in this WSL distribution).
- **No Kubernetes**: Docker is unavailable, so `k3d`/`k3s` cannot run, and
  `sol local infra up`, `sol up`, `sol deploy`, `sol status`'s workload health,
  Grafana, and Alertmanager are all out of reach on this host. Every row that
  needs a cluster is recorded `UNQUALIFIED (needs a cluster)` rather than
  weakened.

The substrate itself is therefore *not* the repository's scripted one; the run
record states exactly what was started and how, so a reader can re-run it.

## How a row is qualified

Each row in `observability-diagnostic-matrix.md` carries the failure walk the
operator actually performs:

- **Symptom** — what an operator/user notices.
- **Detection** — the signal that makes it visible (alert, metric, status line, log).
- **Investigation** — the Sol command or view that narrows it.
- **Cause** — whether the surface names the cause, or leaves a guess.
- **Recovery** — the supported path back.

A row is `QUALIFIED (LOCAL)` only when the run record contains the verbatim
command and its observed output for each of those stages that applies, and the
failure could have produced a different result. A stage that was not reached is
named as `NOT REACHED`, not filled in.

## Current standing

Through run 5 (2026-10-02). Everything below is LOCAL at most; **nothing is
`LIVE`.**

| Area | Qualified | Deferred / unqualified |
|---|---|---|
| Framework telemetry (logs, metrics, traces) | green path end-to-end, trace/log correlation, and the `DEC-064` taxonomy on logs and traces | the deployed path where the manifest injects the identity into a real pod |
| `sol logs` (Loki-first snapshot) | selection, exactness, outage degradation, and a URL pane Grafana can parse | `--release` (needs a cluster's release store) |
| `sol open traces` | workspace/domain/unit TraceQL over the emitted identity; the unit query returns that unit's traces, and a cross-unit trace appears under both | a trace spanning two *domains* (needs two units' ConfigMaps) |
| `sol status` observability block | local backend reachability + degradation; its `Open` block now lists traces | workload health, deployed backend resolution |
| `sol check` | valid case, scope-miss `exit 2` | (none — `BUG-124` fixed) |
| Dashboards | definition/link mapping and proxy query execution | live panel render under a cluster scrape |
| Alerts | rule set present; `SolKafkaConsumerLagHigh` re-verified after `BUG-122`; the delivery route | the `SolTelemetryTargetDown` firing, acknowledgement |
| Failure visibility | Loki loss, unreachable-cluster misdiagnosis, decode-error/DLQ, broker lag | broker loss, telemetry loss |
| Retention / durability | local backend has no promise (by design) | `self_hosted_durable` (AWS-only, cloud-gated) |
| Operator workflows (deploy→fail→rollback→recover) | — | needs a cluster and a target |
