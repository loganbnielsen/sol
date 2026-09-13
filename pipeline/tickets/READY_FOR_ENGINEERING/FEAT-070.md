---
id: FEAT-070
type: feature
severity: medium
source: split out of FEAT-069's 2026-09-13 design review — the deployment-event half of the release model
---

**Depends on:** FEAT-067 (the existing record, which this renames and extends), FEAT-069 (release identity).

**Related:** DEC-018, FEAT-066 (rollback consumes release identity).

Model the *deployment event* as its own object, separate from the release it
attempted to put in place.

## Why this exists

FEAT-067's record conflates two objects: it is minted per deploy (so it is an
event) but its id is called `release_id` (so it reads as an identity). That
ambiguity surfaced immediately in FEAT-069: a content-addressed release can be
deployed more than once, so `release_id.created_at` / `.git_commit` /
`.git_dirty` have no single correct answer once the same release is deployed
twice.

```text
10:00  commit abc  clean   deploy content X
11:00  commit def  dirty   deploy content X
                            │
                            └── both are release r_123, but they are two
                                different events with different provenance
```

## Scope

1. **Rename the event fields into a Deployment object**: `deployment_id`
   (minted per invocation), `release_id` (which release was attempted),
   `created_at`, `git_commit`, `git_dirty`, `actor`, `target`. FEAT-067's record
   is the seed; its `release_id` field historically held a minted value and must
   become `deployment_id`.
2. **Invocation provenance stays here** — never in the pod template, never in
   the release artifact. It must not affect `release_id`, and it must not change
   the emitted bundle for an identical release (FEAT-069).
3. **`sol deployments`** lists events newest first with the release each one
   deployed, so a reader can see *two deploys, one release*:

   ```text
   DEPLOYMENT  RELEASE   TIME    COMMIT
   d_1044      r_8f31c   10:41   abc123
   d_1043      r_8f31c   10:32   abc123
   d_1042      r_a921e   yesterday def456
   ```

4. **Health is not part of the event record.** "Applied" and "healthy" are
   different facts; health is read from the live workload / Argo rather than
   written back into an immutable record.

## Acceptance criteria

- Two deploys of identical content produce **one** `release_id` and **two**
  `deployment_id`s.
- `sol deployments` shows both, with the shared release.
- `release_id` is unchanged by provenance-only differences (commit, dirty,
  actor, timestamp) — asserted by test on the id derivation, not by inspection.
- The emitted bundle is byte-identical for two identical releases.

## Notes

Whether this is one PR or two (rename the record; add `sol deployments`) is a
sizing decision at implementation time. The rename is the load-bearing part,
because it is what makes FEAT-069's `release_id` unambiguous.
