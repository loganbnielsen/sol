# Framework runtime audit — 2026-09-29

Audited clean canonical `main == origin/main` at `5a0da864`, then refiled against `7f6aa377`. The intervening commits (BUG-086, BUG-093 part A) touch CLI cloud and secret-rotation code, not the framework or `cli/bin/cmd_secret.ml` argument handling. Support pins: `kafka-eio` `b2881b31`, `pg-eio` `1cfc9b51`. No finding was implemented.

This continues the retry-relay audit (BUG-096). It covers the framework runtime (`kafka-eio-service`, `sol-worker`, `sol-jobs`, `sol-fn`, `sol-svc`, `sol-runtime`), the `pg-eio` migration runner, worker probe rendering, and `sol secret`.

## Filed

| Ticket | Severity | Finding | Evidence |
|---|---|---|---|
| BUG-097 | High | `Retry_topics` workers ignore `stop`/SIGTERM. The relay fiber also holds the outer switch open. | Broker repro: `In_memory` returned 0.0s after stop; `Retry_topics` still running at 22s. |
| BUG-098 | High | A job that kills its process is reclaimed forever, past `max_attempts`. | Postgres repro: `max_attempts=2`, six kills, row `pending attempts=6`; control ends `failed`. |
| BUG-099 | High | Hard-coded one-partition topics plus assignment-gated readiness and startup probes: idle replicas crash-loop, PDB blocks drains, rollouts can stall. | Broker repro: two replicas, second `/readyz` 503 throughout; code trace of probes, PDB, `node-failure-tolerant` replica rule. |
| BUG-100 | Medium | `sol secret --env` selects nothing and rejects the documented `--env prod` rotation command. | `mode_of_env` and existing tests; docs and help text trace. |

## Candidates rejected

- Schema-registry `FULL` compatibility not enforced for JSON schemas: tested on local Redpanda v26.1.9. Incompatible JSON schemas are rejected with 409, so the contract holds.
- Concurrent migration `apply` racing: each migration runs in a transaction with a `version` primary key, so the loser rolls back. No double-apply.
- `pg-eio` `rollback` reconstructs `%04d_<name>.down.sql`, so 3-digit files (the example Sol's own error text gives) find no down file. It fails closed with a clear message and all shipped examples use 4 digits. Medium at most; not filed.
- `sol migrate apply --dry-run` prints every migration, not only pending ones. Cosmetic.
- `sol-svc` shutdown budget: 5s delay + 30s drain fits the rendered 45s grace period. `docs/reference/runtime.md:84` still says Deployments set no grace period (stale doc, low).
- `sol-fn` stop handling: signal and caller stop race the body explicitly, and a second signal falls back to the default handler. Sound.
- `Kafka_service.publish` takes no key: no per-key ordering is promised. The scaling consequence is folded into BUG-099.
- `sol-jobs` lease overrun: already documented and fenced (BUG-050).

## Limits

- Reproductions were scratch executables linked against the in-repo libraries, not deployed pods. Probe, PDB and rollout consequences in BUG-099 come from rendered-manifest code and Kubernetes semantics, not a cluster run.
- BUG-098 simulated an OOM with self-SIGKILL.
- Only disposable local Redpanda topics and groups and a disposable Postgres container were used, and they were removed afterwards. No cluster or cloud state was touched.

## Addendum — BUG-101

| Ticket | Severity | Finding | Evidence |
|---|---|---|---|
| BUG-101 | Medium | `sol logs` and `sol open logs` select a unit by `{service=~".*<name>.*"}`, matching same-named or longer-named units in other domains and workspaces. | Code trace of all three selector sites; OBS-046's recorded live stream labels (`service` is the bare k8s name); pluto and venus share unit names. Not reproduced against a live Loki. |

## Addendum — design pass (2026-09-29)

Re-read with the explicit standard that correctness and design win over incremental middle grounds (pre-alpha, no compatibility constraint). This rejects "documented, therefore accepted" as a reason not to file, and removes hedged remediations.

| Ticket | Severity | Finding | Evidence |
|---|---|---|---|
| BUG-102 | High | Two retry mechanisms; the reference app uses the non-durable, unbounded, no-DLQ `In_memory` one. | Code/docs trace; pluto and venus call sites. |
| BUG-103 | High | `sol-jobs` leases are never renewed, so overrunning handlers run concurrently. | Code/docs trace (`sol-jobs.md:105-110`). |
| BUG-104 | High | The retry relay releases records in log order, so long delays block records due sooner. | Code trace; documented in `kafka-eio-service.md:340-346`. |
| BUG-105 | High | Every consumer registers its reader schema as a new subject version and resets compatibility at startup. | Local Redpanda: the consumer's schema became `latest`; operator `NONE` reset to `FULL`. |
| BUG-106 | Medium | Migration grammar duplicated between Sol and `pg-eio`; rollback reconstructs `%04d` names; dry-run shows applied migrations. | Code trace. |

Amended in the same pass: BUG-096 (fix in `kafka-eio`'s poll backpressure; withdrew the unverified claim that pausing is insufficient), BUG-098 (catch handler exceptions as failed attempts), BUG-099 (readiness = membership; partitions and key in the event contract; no replica cap), BUG-100 (add `sol local secret`).

**Correction to BUG-096's filing:** the same 600-record backlog through `consume_partitioned`'s pausing retry path (15s backoff) kept a 3.0s maximum poll gap and was not evicted. `In_memory`'s pause therefore does not hit the BUG-096 starvation, and the original claim that pausing is insufficient was unverified.

Previously rejected and now filed: lease renewal (was "documented and fenced"), retry head-of-line (was "documented and accepted"), migration rollback naming (was "fails closed"). Still not filed: peer API keys, because workload identity is an explicit DEC-026 decision, not a middle ground.
