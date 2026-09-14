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
