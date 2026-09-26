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

## Completion notes (2026-09-14)

Landed on `FEAT-072/lease-quiescence-retention`, as a sequence of independently
green commits.

**Boundary lease** — new `Sol_cli_boundary_lease`, with a mutable
`sol-boundary-lease-<workspace>` ConfigMap per workspace in the target's
`default` namespace (the workspace is the boundary: it is what the pointer and
release history are scoped to, and rollback restores a release whole).
Acquisition is an atomic `kubectl create`; a live holder is never stolen. A
holder whose heartbeat is older than `default_ttl_s` (300s) is treated as
crashed and taken over with a `replace --resource-version` compare-and-swap.
The decision of what to do with a holder is pure and unit-tested
(`deploy_decision`/`rollback_decision`); the kubectl writes are the only impure
part.

- `sol deploy`/`sol up` acquire as `Deploy`, refuse if a live operation holds
  the boundary, and release however the run ends. They refresh the heartbeat
  before each workload via a new optional `before_apply` hook threaded through
  `Sol_cli_executor.run_plan`/`Sol_cli_factory.execute`, and stop with a clear
  error if a rollback requested an abort.
- `sol rollback` acquires as `Rollback` *before* its first mutation. Meeting a
  live deploy it requests an abort and polls for quiescence; if it cannot
  establish it within `rollback_wait_s` (300s), it refuses and names the holder.
  A live rollback makes the second refuse rather than fight.
- Release is wired through both `Fun.protect` and `at_exit`: the commands'
  refusal/failure paths call `exit`, which does not unwind `Fun.protect`, so a
  refused rollback would otherwise strand the lease until its TTL.

**Retention** — new `Sol_cli_release_retention`. After a successful deploy/up,
keep the last `--keep-releases N` distinct release records (default 20,
`Sol_cli_release_retention.default_keep`); a value below 1 is rejected at
request construction. Order is the cluster-assigned
`metadata.creationTimestamp` (`Sol_cli_release.parse_kubectl_list_with_creation`
— the record itself deliberately has no timestamp, FEAT-069); duplicate deploys
of identical content collapse to one distinct release. The pointer target and
the release the pointer named before the transition (read under the lease) are
never pruned. Since release records are written only on a successful apply,
"prune only successful releases" is structural: the release store *is* the
successful-release history. Pruning is non-fatal, like recording itself, and
touches only `sol-release-*` ConfigMaps — never the pointer or deployment-event
history.

**Fn / recreate** — premise found this already delivered by FEAT-066 slice 2
(rollback re-renders and re-applies every reconstructed spec, so a CronJob and a
`strategy: Recreate` Deployment are restored, not skipped). Pinned with
regression tests rather than reimplemented: `test_rollback` reconstructs a `Fn`
workload, asserts it is verified as a CronJob, and asserts a `recreate` strategy
survives reconstruction.

**Supporting changes:** `Sol_cli_kubectl` gained `create` / `replace
?resource_version` / `delete`; `Sol_cli_release_store` gained `current`,
`delete` and `list_with_creation`; `Sol_cli_command_request` and the deploy/up
Cmdliner terms gained `keep_releases`.

**Docs:** `docs/architecture/devops-pipeline.md` (mutation boundary + release
retention) and `internal/planning/WORK_SUMMARY.md`.

**Demo/example coverage:** none applies. This changes cross-process coordination
and internal release-history retention, not generated manifests, `sol.toml`, a
primitive, or a new CLI command, so no runnable example or demo would exercise
it.

**Review follow-up — orchestration shape (2026-09-14).** The first push was
bounced for putting several state machines in one `exit`-interleaved
`run_apply`. Reworked so the apply path is a result-returning orchestrator:

- `Sol_cli_boundary_lease` exposes an opaque `held` (context + run id + lease)
  and a `with_boundary_lease` bracket; call sites use `ensure_held lease`, and
  the `at_exit` + `Fun.protect` duplication is gone.
- `Sol_cli_deployment_attempt` names the attempt lifecycle (mint id → apply →
  outcome → exactly one event → marker only once the event exists and the apply
  succeeded).
- `cmd_deploy.run_apply` is lease bracket → previous release → attempt →
  report/record; `cmd_up` mirrors it, and `cmd_rollback.run_locked` returns a
  result too. No command calls `exit` inside the lease — only the command edge
  does.
- Extracting rollback's sequence into an injectable, testable transaction (so a
  future reorder is caught) is now the whole of FEAT-075.

**Still open (not this ticket):** GitOps-mode rollback remains undesigned and
unticketed; `--commit`/`--scope` release selection is FEAT-073; pruning live
Sol-owned workloads a release no longer contains is FEAT-074; the rollback-order
transaction extraction is FEAT-075.

