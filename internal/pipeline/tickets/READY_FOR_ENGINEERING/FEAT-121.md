---
id: FEAT-121
type: feature
severity: medium
title: Wire the outbox through the pluto demo, the tutorial and the workspace migrations
source: "FEAT-111 (the outbox itself); the demo fell out of its PR for a pin-resolution reason"
---

**Depends on:** FEAT-111.

**Blocked On:** FEAT-111, and specifically on it being on `main`. A workspace's Dockerfile
reconstructs the framework dependencies with `opam install --deps-only .`, and `pluto.opam`
pins every `sol-*` package to `git+https://github.com/loganbnielsen/sol.git#main` (DEC-025's
development channel). So a workspace can only name a framework package that `main` already
publishes — adding `sol-outbox` to `pluto.opam` inside FEAT-111's own PR made
`example-dockerfile-smoke` fail with `opam install --deps-only .` exiting 20, because the
package did not exist on `main` yet. This ticket is the second half, by necessity.

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
