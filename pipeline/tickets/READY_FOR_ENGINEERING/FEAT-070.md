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

## Kickoff (2026-09-13, post-FEAT-069 merge)

**Premise re-checked, and corrected.** The scope above says "rename the event
fields" and treats FEAT-067's record as the seed. That is no longer the shape of
the tree. FEAT-069 step 6 rewrote the record (`Sol_cli_release`) into a pure
content artifact — `{ release_id; workspace; environment; workloads }` — and
*deleted* `created_at` / `git_commit` / `git_dirty` / `target` /
`requested_scope` rather than parking them. So there is no minted `release_id`
field left to rename: **FEAT-070 introduces the Deployment object** (model,
minting, persistence, provenance) and leaves the release path alone.

What is actually in the tree at kickoff:

- `Sol_cli_release` / `Sol_cli_release_store` — the immutable content record,
  its `sol-release-<id>` ConfigMaps and the `sol-current-release` pointer. Both
  `sol up` and `sol deploy` write it.
- `Sol_cli_deploy_event` — a *different* object: the OBS-037 per-service Loki
  log marker (`event=deploy`, workspace/env/domain/service/primitive/release)
  that `sol deploy` pushes after apply. Observability, not cluster history.
- `Sol_cli_deployment_state` — a mutable `sol-deploy-state-<workspace>` ConfigMap
  holding the last applied outcome / consumer groups. Not an event log.
- No `deployment_id`, no provenance record, no `sol deployments`.

### The `release_id` audit (classify, do not mechanically convert)

Every site named `release_id` / `release` must be consciously classified:

```text
domain identity         -> Release_id.t        (already so; keep)
display / serialization -> string              (fine)
deployment-event id      -> Deployment_id.t     (new)
```

Known sites and their disposition:

- `sol_cli_deployment_plan.release_id`, the render path, the `release` label, the
  canonical record, `sol logs --release` — **domain identity, unchanged**.
- `Sol_cli_release.t.release_id : string` — the serialized artifact's own name;
  the record *is* the boundary. Unchanged.
- `Sol_cli_deploy_event.release : string` — display/observability field holding
  the release id. Unchanged (may gain a sibling `deployment_id` later).
- `Sol_cli_release_inspection.release_summary.release_id : string` — a
  display/JSON summary with no production caller. **Explicit non-goal:** leave it
  a string. The moment it participates in identity/join semantics it becomes
  `Release_id.t`; converting it before then is churn, not safety.
- New: the Deployment object's `release_id` — the one place the event points at a
  `Release_id`.

### Boundary

```text
FEAT-070 may touch                          FEAT-070 must not need to change
------------------------------------------  -----------------------------------
deployment-event model / persistence        Release_id.of_content
provenance (created_at, commit, dirty,      release_content
  actor, target)                            plan.release_id
minting Deployment_id                        release labels
sol deployments                              canonical release record
existing deploy-event naming / semantics     the release render path and store
```

The leak signal is **not** "the executor threads a `~release_id`" — after 069 the
executor consumes `plan.release_id`. The signal is: *FEAT-070 alters the plan's
release identity, or how render/store derive from it.* If it does, stop and
inspect why.

### Open at kickoff (confirm before writing code)

1. **Minting.** `Deployment_id` mirrors `Release_id` structurally (abstract `t`,
   validated `of_string`, `to_string` only at boundaries) but is minted, not
   content-derived. Proposed: reuse the run-id shape
   (`Sol_cli_run_log.generate_run_id`, `<prefix>-YYYYMMDDTHHMMSSZ-<pid>`) with
   prefix `d` — sortable and aligned with DEC-018's "sortable and unique,
   aligned with the run-id shape".
2. **Persistence.** Proposed: one immutable ConfigMap per deployment
   (`sol-deployment-<id>`, `immutable: true`) in the target's `default`
   namespace, labelled for lookup, mirroring the release record so self-hosted
   history is recoverable from the cluster without Sol Cloud (DEC-018).
   `sol deployments` reads them via kubectl, newest first. Alternative: query the
   Loki deploy-event stream (reuses OBS-037, but needs Loki and misses offline).
3. **Naming.** Proposed: `Sol_cli_deployment` / `Sol_cli_deployment_id` /
   `Sol_cli_deployment_store`, leaving the OBS-037 `Sol_cli_deploy_event` as-is;
   optionally add `deployment_id` to its fields so a Grafana timeline can join.
4. **Sizing.** One PR: the "rename" half no longer exists, so the load-bearing
   part is the new object plus persistence, and `sol deployments` is a thin
   reader over it.
