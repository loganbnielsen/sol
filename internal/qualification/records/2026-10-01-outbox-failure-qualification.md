# Qualification record — transactional outbox, local failure run (2026-10-01)

Ticket: `FEAT-120`. This is a **local** run of the recommended composition, not a cloud run:

```text
domain transaction + outbox  →  Kafka fact  →  sol-worker  →  sol-jobs  →  retryable effect
```

It is the README's run-local path — the example's own worker binary against a broker and a
Postgres database — with a dedicated, isolated broker so the shared one was never touched.

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `44e3061b2b63c9cdef32567fc279f062d5a724a2` | `git rev-parse HEAD` at run start (branch `FEAT-120/outbox-failure-qualification`) |
| Working tree state | clean | `git status --porcelain` |
| Program under test | `examples/pluto/app/comms/notify_worker/bin/main.exe` | built from that revision |
| Broker | an isolated Redpanda container `sol-qual-redpanda` (kafka `:19092`, schema registry `:18081`, admin `:19644`) | `rpk -X brokers=localhost:19092 cluster health` → `Healthy: true` |
| Schema registry | the isolated one; subjects registered by `contract/contract.exe --apply` | `Charged` id 1, `Notification_sent` id 2 |
| Database | `outbox_qual` on the local Postgres (`postgresql://postgres:dev@localhost:5432/outbox_qual`) | migrations `0001_notifications`, `0002_sol_jobs`, `0003_sol_outbox` applied |
| Started (UTC) | 2026-10-01T13:13Z | |
| Finished (UTC) | 2026-10-01T13:18Z | |

The `Charged` events are produced as the Confluent wire format (`0x00 || schema_id || json`),
keyed by the charge id. The isolated broker was used so that the outage scenario could stop *a*
broker without disturbing the shared one.

## 2. Step log

### S0 — happy path (baseline) — **PASS**

- Produce: `printf '\x00\x00\x00\x00\x01{...}' | rpk -X brokers=localhost:19092 topic produce
  pluto-payments-charges --format '%v{hex}\n' -k q-baseline` → `Produced to partition 2 at offset 0`.
- Worker:

  ```text
  log.level=info log.msg=charge event received charge_id=q-baseline customer_id=cust-q amount_cents=1000
  sol_worker_messages_total counter=1 labels={status=ok}
  sol_outbox_published_total counter=1 labels={kind=notification_sent status=ok}
  [notify-worker] confirmation email sent  charge=q-baseline  customer=cust-q
  sol_jobs_processed_total counter=1 labels={status=ok kind=send_confirmation_email}
  ```

- Durable state: `sol_outbox=0`, `pluto_notifications=1`, `sol_jobs=1 completed`.
- Kafka: `q-baseline | \x00\x00\x00\x00\x02{"charge_id":"q-baseline","customer_id":"cust-q","amount_cents":1000,"currency":"USD"}`.

The relay removes the row only after the broker acknowledged: the outbox is empty **and** the
fact is on the topic.

### S1 — duplicate delivery of the same domain event — **PASS with a finding**

Re-produced the same `q-baseline` event (same charge id, same key):

```text
Produced to partition 2 at offset 1
sol_outbox_published_total counter=1 labels={kind=notification_sent status=ok}   (a second time)
```

- `pluto_notifications=2` — **the duplicate inserted a second notification row.**
- `sol_jobs=1` — the independent effect did **not** run twice; `~dedupe_key:msg.id` held
  (FEAT-112).
- Two `q-baseline` records on `pluto-comms-notifications`.

So the *independent effect* is idempotent under duplicate delivery, and the *domain write is
not*: a redelivered fact duplicates the notification. The outbox contract says duplicates are a
legal outcome and consumers must be idempotent; the representative demo does not demonstrate
that for its own domain write. Filed as **BUG-112**.

### S2 — originating transaction rolls back after enqueueing — **PASS**

Seeded a conflicting row — `INSERT INTO sol_outbox ... ('notification_sent','q-roll',1,'{}')` —
then produced `q-roll`. The handler's transaction inserts the notification, enqueues the job and
publishes the outbox intent; the outbox insert collides:

```text
log.level=error log.msg=db insert failed error=constraint violation: ... ERROR:  duplicate key
value violates unique constraint "sol_outbox_key_ord_idx" DETAIL: Key (aggregate_key, ord)=(q-roll, 1) already exists.
```

Asserted all three, not just the domain row:

```text
notif_q_roll=0
jobs_q_roll=0
outbox=1 keys=q-roll          (only the seeded row)
```

No Kafka fact for `q-roll` was produced. The notification row **and** the job **and** the
publication intent all rolled back together.

### S3 — worker `Fail` — **PASS**

Same run as S2:

```text
sol_worker_messages_total counter=1 labels={status=fail}
log.level=error log.msg=sol-worker: handler failed a fact; the offset is not committed and the consumer stops.
  This is a contract failure, not a retryable one: fix the handler or the fact, then restart.
kafka-eio: handler returned without calling ack() — offset not committed (topic=pluto-payments-charges partition=0 offset=0)
```

The process exited (the consumer stopped). After the conflicting fact was removed and the worker
restarted, the uncommitted offset was redelivered and `q-roll` committed — no gap.

### S4 — Kafka unavailable after the transaction commits, then recovery — **PASS**

`docker stop sol-qual-redpanda`, then committed a publication intent directly
(`INSERT INTO sol_outbox ... ('notification_sent','q-outage',1,'{"charge_id":"q-outage",...}')`).
The relay could not publish and the row was held — no advance past it, no loss:

```text
rdkafka#producer-1 ... Connect to ipv4#127.0.0.1:19092 failed: Connection refused
outbox=1 keys=q-outage
sol_outbox_pending gauge=1 labels={kind=notification_sent}
sol_outbox_oldest_pending_seconds gauge=4.35766 labels={kind=notification_sent}
```

The last two lines are the publication-lag signal the contract promises: the blocked key raises
its kind's pending count and oldest-pending age immediately.

`docker start sol-qual-redpanda`, then:

```text
sol_outbox_published_total counter=1 labels={kind=notification_sent status=ok}
outbox=0
Kafka: 1 q-outage
```

The fact arrived and the row was removed once the broker acknowledged. (The produce receipt
*blocks* while the broker is unreachable — rdkafka's message timeout — rather than failing fast,
so the relay holds the row; either way it does not advance and does not lose it.)

### S5 — same-key ordering — **PASS**

With the relay stopped, inserted `ord=2` **before** `ord=1` for one key (`q-order`), the payload's
`customer_id` encoding the token (`seq2`, `seq1`). On restart the consumer observed them in
order of the token, not of insertion:

```text
$ rpk ... consume pluto-comms-notifications --offset start --format '%k|%v\n' | (key q-order)
seq1
seq2
```

Nothing advanced that key past its earlier unpublished event.

### S6 — relay restart / recovery — **PASS (partial)**

The worker was restarted between S2 and S4, and again for S5. Both times it resumed publishing
rows left pending (the delayed `q-roll` redelivery; the held `q-outage` row) in order, with no
gap. A restart *during a publish* (S7) was not forced.

### S7 — crash between broker ack and the database mark — **NOT REACHED**

There is no hook to kill the relay precisely between the receipt resolving and the row's
`DELETE`. The property is asserted by the package's own Postgres-backed test
(`test_a_row_is_kept_until_the_receipt_resolves`) but is **not observed live** in this run. A run
that forced it would be expected to produce a duplicate prefix (never an inversion or a gap).

### S8 — job retry in `sol-jobs` — **NOT REACHED**

The demo's job handler (`send_confirmation_email`) cannot fail, so no transient job failure could
be injected without changing the application. What *was* observed: there is **no Kafka retry
topic** — the isolated broker's topics are exactly

```text
pluto-comms-notifications
pluto-payments-charges
pluto-payments-charges.pluto-comms-notify-worker-453d19622484.dlq   (decode-error DLQ only)
```

so the independent effect's retry path is `sol-jobs`, not a Kafka application retry topic
(FEAT-113).

## 3. What this run does not establish

- It is **not** the deployed `sol up` path. It is the run-local path: the example's own process
  against a broker and database on the same host.
- The crash-boundary duplicate (S7) and job retry/backoff (S8) are unobserved.
- Multi-replica relay contention is not exercised (v1 is one logical owner by design).
- The `Charged` events were produced out of band (the example's `charge_svc` accepts through
  Postgres by design), so the producer half is not the application under test.

## 4. Findings

- **BUG-112** — the representative consumer is not idempotent for its domain write: a duplicate
  fact inserts a second `pluto_notifications` row (the jobs effect is deduped). File under
  `BACKLOG/`.
