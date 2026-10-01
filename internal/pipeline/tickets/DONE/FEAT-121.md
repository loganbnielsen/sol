---
id: FEAT-121
type: feature
severity: medium
title: Wire the outbox through the pluto demo, the tutorial and the workspace migrations
source: "FEAT-111 (the outbox itself); the demo fell out of its PR for a pin-resolution reason"
---

**Depends on:** FEAT-111.

**Premise verified (2026-10-01):** `FEAT-111` is on `main` (`git log origin/main` ->
`017fe4d9 FEAT-111: a Postgres transactional outbox with per-key ordered publication`), so
`framework/ocaml/sol-outbox` is published on the development channel a workspace pins
(`sol.git#main`) and a workspace can name it. The blocker is resolved; the ticket is
promoted to `READY_FOR_ENGINEERING`.

**Why it was blocked:** a workspace's Dockerfile reconstructs the framework dependencies
with `opam install --deps-only .`, and `pluto.opam` pins every `sol-*` package to
`git+https://github.com/loganbnielsen/sol.git#main` (DEC-025's development channel). So a
workspace can only name a framework package that `main` already publishes — adding
`sol-outbox` to `pluto.opam` inside FEAT-111's own PR made `example-dockerfile-smoke` fail
with `opam install --deps-only .` exiting 20, because the package did not exist on `main`
yet. This ticket is the second half, by necessity.

## What to do

- Workspace migrations, so the table exists: `db/migrations/0003_sol_outbox.sql` in
  `examples/pluto`, `internal/fixtures/venus` and the scaffold template
  (`platform/shared/templates/workspace`), and the matching expectations in
  `cli/test/test_workspace_model.ml` (it asserts a migration count per workspace).
- `examples/pluto`: declare the `Notification_sent` event (`events/comms/notification_sent.ml`,
  topic `pluto-comms-notifications`), have the notify worker publish the intent in the same
  transaction as the notification row and the confirmation-email job, and host the relay in
  `bin/main.ml` — publishing through the topic handle, so the event's key is the Kafka key
  and the receipt is awaited before the row is removed. Add `sol-outbox` to `pluto.opam`
  (both `depends` and the `pin-depends` block) and to the app's dune files.
- The tutorial (`docs/guides/TUTORIAL.md` § The worker) shows the same shape and states the
  duplicate/gap contract where an app author reads it.

## Acceptance criteria

- `sol up` on pluto starts the notify worker with a relay that publishes a
  `Notification_sent` event for a consumed `Charged` event, and `example-dockerfile-smoke`
  and `golden-path-smoke` pass with `sol-outbox` in the workspace's dependency list.
- The migration makes `sol_outbox` exist in a scaffolded workspace, and the workspace-model
  test expects it.
- The tutorial's worker section matches the code.

**Demo/example coverage:** this ticket *is* the demo coverage for FEAT-111.

**TypeScript parity:** no change from FEAT-111's verdict (deferred with a trigger; the
`@sol-fab` packages have neither a job queue nor an outbox to extend).

## Completion notes (2026-10-01)

### What landed

- `examples/pluto`: a `Notification_sent` event (`events/comms/notification_sent.ml`, topic
  `pluto-comms-notifications`, `partitions = 3`, keyed by `charge_id`), registered in
  `contract/contract.ml` and `test/test_schemas.ml`. The notify worker writes the notification
  row, enqueues the confirmation-email job and calls `Sol_outbox.publish` in **one**
  `Pg_db.transaction`; `bin/main.ml` registers the topic handle and hosts the relay, whose
  publish callback decodes the payload, calls `Kafka_service.publish` and awaits the receipt
  before the outbox row is removed. `sol-outbox` is in `pluto.opam` (`depends` and
  `pin-depends`) and in the app's dune files.
- `db/migrations/0003_sol_outbox.sql` in `examples/pluto` and `internal/fixtures/venus`, and
  `db/migrations/0002_sol_outbox.sql` in `platform/shared/templates/workspace`. The migration
  counts in `cli/test/test_workspace_model.ml` and `cli/test/test_scaffold.ml` are updated.
- `platform/local/scripts/prepare-framework-deps.sh` pins and installs `sol-outbox` as well, so
  a checkout's dev workspace can build the example.
- `docs/guides/TUTORIAL.md` § The worker shows the outbox publish in the transaction and the
  relay, states the duplicate/gap contract, and refreshes the workspace file tree and count.

### Acceptance mapping

| Criterion | Evidence |
|---|---|
| `sol up` on pluto starts a relay that publishes `Notification_sent` for a consumed `Charged` | the run below |
| `example-dockerfile-smoke` / `golden-path-smoke` with `sol-outbox` in the dependency list | CI on this PR — the smoke Docker build runs `opam install --deps-only .`, which resolves `sol-outbox` from `sol.git#main` |
| `sol_outbox` exists in a scaffolded workspace and the workspace-model test expects it | `sol new workspace` -> the migration is present; `dune test cli/test` (`test_pending_migrations_workspace_scaffold` = 2) |
| The tutorial's worker section matches the code | tutorial updated above |

The runtime observation ran the example's own worker binary against the local broker and
Postgres (the README's run-local path, not a bespoke harness) and produced one `Charged` event
out of band:

```text
$ contract.exe --apply
contract Charged: registered (schema id 12)
contract Notification_sent: registered (schema id 13)

$ notify_worker/bin/main.exe                 # started against localhost:9092 / :5432
$ echo '{"id":"ch_validate_1","amount_cents":4999,"customer_id":"cust-001","currency":"USD","correlation_id":"c-abc123"}' \
    | rpk topic produce pluto-payments-charges --schema-id 12 -k ch_validate_1
Produced to partition 2 at offset 0 with timestamp 1790831737066.

# worker log:
log.msg=charge event received charge_id=ch_validate_1 customer_id=cust-001 amount_cents=4999
sol_outbox_published_total counter=1 labels={kind=notification_sent status=ok}
[notify-worker] confirmation email sent  charge=ch_validate_1  customer=cust-001
sol_jobs_processed_total counter=1 labels={status=ok kind=send_confirmation_email}

$ rpk topic consume pluto-comms-notifications --offset start --num 1
ch_validate_1 | \x00\x00\x00\x00\r{"charge_id":"ch_validate_1","customer_id":"cust-001","amount_cents":4999,"currency":"USD"}

$ SELECT count(*) FROM sol_outbox           -> 0   (deleted once the broker acked)
$ SELECT ... FROM pluto_notifications      -> one row (ch_validate_1)
$ SELECT ... FROM sol_jobs                 -> send_confirmation_email | completed | 1 | ch_validate_1
```

The whole path is observable, not inferred from an exit code: the broker holds a keyed,
schema-registered `Notification_sent` record; the outbox row is gone; the notification and the
completed job are durable. Deployed `sol up` was not run here; this is the same process the
notify-worker image runs, and its Dockerfile is the one `example-dockerfile-smoke` builds. The
deployed failure qualification is FEAT-120.

### Deviations and notes

- The ticket asked for `0003_sol_outbox.sql` in the scaffold template, but the scaffold carries
  only `0001_notifications.sql` (no `0002_sol_jobs.sql`), so the outbox migration is numbered
  `0002_sol_outbox.sql` there rather than leaving a gap. Reconciling the scaffold with the
  jobs/outbox shape the tutorial documents is EXP-025's wider drift.
- `internal/fixtures/venus` gets the migration only, per the ticket's "so the table exists";
  venus's notify worker is not wired to the outbox here.
- **`examples/pluto`'s notify worker consumes `Charged`, but nothing in that workspace produces
  it** — pluto's `charge_svc` accepts through Postgres by design, while the scaffold's
  `charge_svc` publishes the event. The observation above produced `Charged` out of band.
  Whether pluto should gain an in-workspace producer is a demo-completeness question to settle
  against FEAT-120's live run.

**TypeScript parity (DEC-022):** unchanged from FEAT-111 — deferred with a trigger; the
`@sol-fab/*` packages have neither a job queue nor an outbox to extend (FEAT-119 tracks the
wider TypeScript contract gap).
