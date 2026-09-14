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

## Completion notes (2026-09-13)

**Premise corrected, then built.** FEAT-069 had already deleted FEAT-067's
provenance fields, so this landed as an *introduce*, not a rename: the
Deployment object, minting, persistence, `sol deployments`, and the Loki join
key. The release path (`Release_id.of_content`, `release_content`,
`plan.release_id`, the `release` label, the canonical record, the
render/store) was not touched — the boundary held.

### What landed

- `Sol_cli_deployment_id` — `d-<YYYYMMDDtHHMMSSz>-<16 lowercase hex>`, minted,
  sortable, collision-resistant across actors. Abstract `t`, validated
  `of_string`, `to_string` only at boundaries; `create ~now ~entropy` is
  injectable so tests pin it (known vector
  `d-20260101t000000z-900150983cd24fb0`). Lowercase time because the id is
  embedded verbatim in the ConfigMap name and RFC 1123 names are lowercase.
  `created_at` is the event's own field and is never reconstructed from the id.
- `Sol_cli_deployment` — the event record: `deployment_id`, `release_id` (the
  release attempted), `workspace`, `environment`, `created_at`, `git_commit`,
  `git_dirty`, `actor` (`SOL_ACTOR`), `target`, `mode`, `requested_scope`.
  Deterministic JSON; an immutable `sol-deployment-<id>` ConfigMap with
  `sol.dev/type=deployment`, `sol.dev/workspace`, `sol.dev/release` and (when
  known) `sol.dev/target` labels. `validate` checks the name, the id, and that
  the release pointer parses.
- `Sol_cli_deployment_store` — append-only immutables (no pointer; history is a
  log, not a mutable "current deployment") plus a workspace-scoped list.
- Wiring: `sol up` and `sol deploy` mint an id after a successful apply and
  record the event, non-fatally, alongside the release record. `--dry-run` and
  `--emit-to` record no event (nothing was applied). `sol deployments` and
  `sol local deployments` list newest first.
- OBS-037 marker: `Sol_cli_deploy_event` gained `deployment_id` as a logfmt
  **field** — deliberately not a Loki stream label, because it varies per
  invocation and would put unbounded cardinality into the index. The marker and
  the record now join by id.

### Acceptance criteria

- **Two deploys of identical content → one release_id, two deployment_ids** —
  `test_deployment`'s "two deploys, one release" builds one plan, mints two ids,
  varies commit/dirty/actor/time, and asserts the release is unchanged.
- **`sol deployments` shows both, with the shared release** — the table is
  DEPLOYMENT / RELEASE / TIME / COMMIT, newest first ("table is newest first");
  the command reads the ConfigMaps directly.
- **`release_id` is unchanged by provenance-only differences** — pinned by the
  same test at the id derivation, not by inspection.
- **The emitted bundle is byte-identical for two identical releases** — the
  deployment event is not in the bundle at all (cluster-side provenance);
  FEAT-069's determinism tests still pass unchanged.
- **Health is not part of the event record** — the ConfigMap is
  `immutable: true` and nothing writes a status back to it;
  `Sol_cli_deployment_state` remains the separate mutable "last applied" object.

### `release_id` audit outcome

- Domain identity, unchanged: `plan.release_id`, the render path, the `release`
  label, `Sol_cli_release.t.release_id`, `sol logs --release`.
- Display/serialization: `Sol_cli_deploy_event.release` (now with a
  `deployment_id` sibling), and
  `Sol_cli_release_inspection.release_summary.release_id : string` — **explicit
  non-goal**, left a string because it has no production caller; it becomes
  `Release_id.t` only when it participates in identity.
- The new event's `release_id` is the one place a deployment points at a release.

### Deviations / notes

- The namespace is the target's `default`, matching the release record. That is
  a convention, not a semantic requirement: if Sol later owns a `sol-system`
  namespace, target metadata (release + deployment records) belongs there.
- No pointer object for deployments: unlike "current release", there is no
  "current deployment" to name — the log is the record.
- Deployment ids are `d-<time>-<entropy>`, not the run-id
  `<prefix>-<time>-<pid>` shape: pid is process-local and collides across
  independent actors, which is the wrong uniqueness primitive for a durable id.

### Verification

`dune build`, `dune fmt` (clean), full `dune test` green; new tests
`test_deployment_id` (9) and `test_deployment` (10), plus the deploy-event field
assertion. Pre-commit's build+unit run passed on each commit.
