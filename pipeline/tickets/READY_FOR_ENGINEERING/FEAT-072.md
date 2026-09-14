---
id: FEAT-072
type: feature
severity: medium
source: split from FEAT-066, 2026-09-14 — slice 3 of the DEC-018 rollback work
---

**Depends on:** FEAT-066.

**Related:** FEAT-066 (slice 2, the rollback itself), DEC-018.

The remaining DEC-018 rollback work, split out of FEAT-066 so slice 2 can land
as a reviewable unit (the same way slice 1 was split into FEAT-067).

## Premise verification (2026-09-14, kickoff)

Checked in `main` at `89b4a537`:

- **Lease/quiescence — still missing.** `rg -i 'lease|quiesce|boundary.?lock' cli framework`
  finds no coordination object, and neither `cmd_deploy`/`cmd_up` nor
  `cmd_rollback` takes any boundary lock before mutating. Real work.
- **Retention — still missing.** The only prune logic in the tree is
  `Sol_cli_run_log.runs_to_prune` (local run-log directories); no release-record
  retention exists. Real work.
- **Fn / recreate — already delivered by FEAT-066 slice 2; this bullet is
  stale.** Slice 2 replaced `kubectl rollout undo` with reconstruct-from-record
  + re-render + apply (`cmd_rollback.ml`), which applies *every* reconstructed
  spec — `Fn` renders a CronJob and `recreate` a `strategy: Recreate`
  Deployment — and `Sol_cli_rollback.live_kind_of_service` already maps
  `Fn -> Live_cronjob`, so neither shape is skipped. The old
  `rollback_target_of_service`/`No_op` path is deleted. Action: pin the
  behaviour with a regression test, not a redundant mechanism.

## Kickoff design (2026-09-14)

**Boundary lease.** One mutable ConfigMap per workspace in the target's
`default` namespace, `sol-boundary-lease-<workspace>`, labelled
`sol.dev/type=boundary-lease`. `sol deploy`/`sol up` (holder `deploy`) and
`sol rollback` (holder `rollback`) acquire it before the first mutation and
release it after. Acquisition uses `kubectl create` (atomic); a live holder is
never stolen. A holder whose heartbeat is older than a TTL is stale (crashed or
killed) and may be taken over with a `resourceVersion` compare-and-swap. A
rollback that meets a live deploy requests an abort and waits for the lease to
go quiet; if the holder keeps heartbeating past the wait bound, rollback refuses
and names the holder rather than racing it. Deploy refreshes the heartbeat
before each workload apply and stops cleanly if an abort was requested.

**Retention.** Release records are written only on a successful apply
(`cmd_up.ml`/`cmd_deploy.ml`), so the release store *is* the successful-release
history — there is no failure filter to apply. Order by each release
ConfigMap's cluster-assigned `metadata.creationTimestamp`; keep the most recent
`keep` (default 20, `--keep-releases`), and never prune the current pointer
target or the release the pointer named before this transition. Pruning runs
after a successful deploy/up records and re-points, so both "current" and
"previous" are well-defined. Only `sol-release-*` records are touched;
deployment-event history is a separate retention question (DEC-018).

**Fn/recreate.** Pin the already-delivered slice-2 behaviour with a
reconstruction + live-kind regression test rather than reimplementing it.

## Work

1. **Lease and quiescence.** One lease per target/scope boundary, shared with
   deploy: abort an in-flight deploy, wait for quiescence, and refuse if
   quiescence cannot be established — rather than mutating a boundary that is
   still moving.
2. **Function / recreate reconciliation.** Rollback for `Fn` (CronJob) and
   `recreate`-strategy workloads, where "the previous revision" is not a native
   concept the way it is for a rolling Deployment.
3. **Retention.** Keep the last 20 successful releases per target
   (configurable); never prune the current or previous release, and prune only
   successful releases.

## Acceptance criteria

- A rollback that cannot establish quiescence refuses and says why.
- An in-flight deploy and a rollback cannot both mutate the same boundary.
- `Fn` and `recreate` workloads roll back to the recorded boundary rather than
  being skipped.
- Retention prunes only successful releases beyond the window, and never the
  current or previous one.

## Notes

These bullets were FEAT-066's slices 2–3 acceptance criteria; they move here so
FEAT-066 describes only what it delivers.
