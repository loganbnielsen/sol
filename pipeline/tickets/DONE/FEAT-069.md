---
id: FEAT-069
type: feature
severity: medium
source: discussion 2026-09-13 — release identity should join "what did I deploy?" to "what happened after I deployed it?"
---

**Depends on:** FEAT-067 (the release record), FEAT-063 (destinations, for `--target` on the query).

**Related:** FEAT-026 / OBS-016 / OBS-021 (the taxonomy labels and their sanitizer), OBS-039, DEC-018.

Make one release identity span the deploy record and the observability data, so a release is the join key between a deploy and its telemetry.

## What already exists (checked 2026-09-13)

More than expected, which is why this is a narrow ticket rather than a new subsystem:

- `Sol_cli_manifest_yaml.render_taxonomy_labels` already renders a **`release`** label into every pod template, alongside `workspace`, `domain`, `service`, `primitive` (and `env` when a target resolved one). Its value today is `release_of_image image` — **the image tag**.
- `Sol_cli_dev_observability` already carries `release` in the Alloy/Loki taxonomy label set (`~taxonomy_labels:[ "workspace"; "domain"; "service"; "primitive"; "release" ]`), and there is a `release-timeline.json` dashboard.
- So logs and traces are already taggable by release; the propagation exists.

## The gap

**Two different things are called "release", and they don't agree.**

- The **taxonomy label** is the image tag (`release_of_image image`).
- The **release record** (FEAT-067) has its own `release_id`, minted at record time as `<YYYYMMDDtHHMMSSz>-<commit>` and never equal to the image tag.

So `sol releases` names a release one way and the telemetry labels it another; you cannot go from a listed release to its logs.

There is also no query: `sol logs`'s Grafana link selects `{namespace=…,app=…}` with no `release=` term, and there is no `--release` flag.

## Scope

1. **Define `release_content` and `Release_id.of_content`.** A pure, canonical
   projection of the deployment inputs, and a content-addressed id over it.
   Label-safe by construction; `of_string` validated so tests and deserialization
   can construct one.
2. **Put `release_id` on the plan**, established before render. Every plan has
   one, including `--dry-run` and `--emit` — recording is a side-effect
   decision, having an identity is not, and it keeps execution mode from
   changing the plan's shape (REFAC-089's separation).
3. **The taxonomy `release` label carries the release id verbatim**, not the
   image tag. The image tag stays available as its own fact; it is a
   build/artifact identity, and one release can span several images.
4. **Emit the release metadata with the bundle**: an immutable
   `sol-release-<id>` record plus the `sol-current-release` pointer, both
   deterministic for a given id, so GitOps stays idempotent and the record is an
   applied artifact rather than a CLI side effect.
5. **`sol logs --release <id>`** (and the `sol status` / `sol open` links) key on
   `release_id`; an unknown id fails closed naming recent releases.
6. **Do not add release as an unbounded Prometheus label.** Releases accumulate
   forever; metrics correlate through deployment metadata and/or a bounded
   current-release info metric. Record which.

## Acceptance criteria

- The `release` label on a rendered workload equals the id `sol releases` lists for that deploy.
- `sol logs --release <id>` filters to that release's logs (assert on the built selector).
- The image tag is still visible somewhere (label or annotation) — replacing it is not the goal.
- Metrics do not gain a per-release time-series dimension; the chosen correlation mechanism is documented.

## Notes

The user's framing: `target/environment + service + release` is the coordinate system for observing a deployed workload, and a release becomes the join key between "what did I deploy?" and "what happened after I deployed it?" — which is a much larger payoff than release bookkeeping alone.

## Design review 2026-09-13 — agreed model

**Release identity is an input to rendering, not something the release store
synthesises afterwards.** The flow:

```text
command boundary
      │
      ▼
release id established
      │
      ▼
deployment plan (carries it)
      │
      ▼
render manifests ────► pod/template labels: release = <id>
      │                 deploy events
      ▼
apply
      │
      ▼
record the release (same id)
```

**The id lives on the plan**, not as a `string` threaded through several
systems. Then the invariant is structural rather than conventional:

```text
one plan = one release identity
```

and every consumer reads `plan.release_id`: manifest labels, deploy events, the
release record, and the query selectors.

**Every plan has an id, including `--dry-run` and `--emit`.** Recording is a
side-effect decision; having an *identity* is not. This also keeps execution mode
from changing the plan's shape, which is the same separation REFAC-089 just
established (`mode` is outside the facts being executed).

**The id must be label-safe by construction**, not sanitized at the render site.
If the render path sanitizes a value that the record stores raw, the label and
the record disagree and the join key breaks — the BUG-025 failure mode in a new
place. So the label is written verbatim from the canonical id.

**`--release` fails closed naming what exists**: an unknown id should say so and
list recent releases, the same way scope resolution refuses an unknown unit
(FEAT-065).

## Model (settled 2026-09-13)

**Two domain objects, not one.** FEAT-067's record conflated them (its id was
minted per deploy but named `release_id`), which is why the `created_at`
contradiction appeared: a content-addressed id can be deployed twice, so
`release_id.created_at` has no single correct answer.

```text
Release                                Deployment (event)
  release_id = hash(content)             deployment_id = minted per invocation
  workloads / images / config / scaling  release_id  (which release was attempted)
  deterministic for given content         created_at, git_commit, git_dirty,
  appears on workload labels                actor, target
  sol logs --release keys on this         NOT on labels; provenance/audit only
```

- **`release_id`** is the content-addressed identity of *desired released state*.
  Same desired workload ⇒ same release ⇒ same id ⇒ **no rollout merely because
  Sol ran again**. Observability metadata must never be the thing that mutates
  the workload it observes.
- **`deployment_id`** identifies one invocation. It never appears in the pod
  template and never determines log ownership. `sol deployments` can list
  history (`d_1044 r_8f31c 10:41 abc123`, `d_1043 r_8f31c 10:32 abc123` — two
  deploys, one release, because nothing substantive changed); see **FEAT-070**.

### The canonical content projection — do not hash the plan

```ocaml
type release_content =
  { workspace : string
  ; environment : ...
  ; workloads : workload_release list
  }

val Release_id.of_content : release_content -> Release_id.t
```

Only fields whose difference means *this is a different running release*.
Explicitly excluded: `created_at`, `requested_scope`, `output_directory`,
`git_dirty`, `deployment_id`, and `release_id` itself. Two reasons:
it stops identity churn when somebody later adds a field to `deployment_plan`;
and it breaks the obvious recursion, since the plan carries the id and the
manifests carry the id.

```text
deployment inputs
      │
      ▼
canonical release_content
      │
      ▼
Release_id.of_content
      │
      ▼
deployment_plan { release_id; … }
      │
      ▼
render labels with release_id
```

### Labels

The label carries `release_id` verbatim, and the id is **label-safe by
construction** — never sanitized at the render site. If the render path
sanitizes a value the record stores raw, the label and the record disagree and
the join key breaks silently (BUG-025 in a new place). `of_string` validates.

### Secret references — a rule to state, not an accident

Hashing *references* means rotating a secret's value does **not** change the
release. That is defensible (secrets are operational state, independent of
releases) but it must be a deliberate rule. If secret versions are ever part of
release identity, hash an immutable version/digest — never the value.

### GitOps: the record travels in the bundle

The emitted bundle *is* the release artifact, so the metadata travels with it:

```text
sol deploy --emit-to ./out
      │
      ▼
release bundle
  ├── deployment.yaml / service.yaml / config.yaml
  ├── sol-release-<id>.yaml      (immutable, named by release id)
  └── sol-current-release.yaml   (mutable pointer → the current id)
```

- **The emitted release record must be deterministic for a given
  `release_id`** — no `created_at`, no `git_dirty`, no invocation id. Otherwise
  every render churns the diff and the "same content ⇒ same diff" property that
  makes GitOps idempotent is destroyed.
- Invocation provenance is deployment-event metadata, which is why it belongs
  to the Deployment object rather than the release artifact.
- **Record semantics: "this release exists / was applied to this target" — not
  "this release reached healthy state."** Argo can apply the record and the
  Deployment can still crash-loop. Health is read from the live workload /
  Argo and never written back into the immutable record.
- Cluster shape is therefore mode-independent: immutable `sol-release-<id>`
  history plus one mutable `sol-current-release` pointer, whether the applying
  actor is Sol or Argo. Only the actor changes; the semantics do not.

### The query

`sol logs --release <id>` (plus `sol status` / `sol open` links) adds
`release="<id>"` to the selector and keys on `release_id`. An unknown id fails
closed and names recent releases, the same way scope resolution refuses an
unknown unit (FEAT-065).

## The rule, sharpened

> Give important identities and environmental facts a single authoritative
> representation, establish them before side effects, and pass them downward
> rather than rediscovering them.

Adding the criterion for *what groups together*, which REFAC-089 just taught:
group by **lifetime and authority**, not by count. `cluster`/`workspace`/`env`
share the lifetime of one execution; `mode` lives for one call; a release id
lives for one plan. Facts that share a lifetime belong in one value; facts that
do not, must not be flattened into one.

## Decisions carried into 5b-7 (2026-09-13)

**5b — the render path keeps the abstract type.** `render_taxonomy_labels` takes
`~release_id : Release_id.t`, not a `string`; `Release_id.to_string` is called
only at the YAML serialization edge. That preserves the guarantee the abstract
type was introduced for: inside the render path nothing can feed an image tag, an
arbitrary string, or a malformed id into the release label.

Do **not** introduce a render-context record for this. One fact is a labelled
parameter; a context type is only earned when several release-level facts
accumulate together. The fan-out is contained and legitimate:

```text
plan.release_id
    ↓
executor render boundary
    ↓
render_spec
    ↓
primitive renderer
    ↓
render_taxonomy_labels
```

That is data reaching the code that needs it — not the cross-layer threading that
made `ctx` a smell. Note also that `~image` drops out of
`render_taxonomy_labels` entirely: the image tag is already its own fact as
`container.image`, and re-emitting it as a label would import the same
unbounded-cardinality problem as a Prometheus label.

**6 — record and pointer, and what inconsistency means.** Keep it simple:

```text
immutable release record   describes r-X
sol-current-release        says r-X is the selected release
```

An inconsistency between them (record content not matching its name; pointer
naming a release with no record) is **detectable invalid state**, not something
to reconcile in place. The pointer payload stays minimal — `release_id` only —
so there is exactly one authoritative immutable description of a release rather
than a copy that can drift.

**6 — the test that proves the promise at the artifact layer:**

```text
same release_content
  => same release_id
  => byte-for-byte equivalent immutable release record
```

(modulo deterministic YAML formatting). `Release_id.of_content` being
deterministic is not enough; the *record* derived from it must be too, or the
GitOps empty-diff property fails one level below the label.

**7 — malformed and unknown are different failures:**

```text
sol logs --release banana        -> invalid release id "banana"
sol logs --release r-0123456789abcdef
                                 -> release r-0123456789abcdef is not known in target staging
```

`Release_id.of_string` already makes that separation natural, and the second
message should name the target it looked in.

**Not claimed:** Kubernetes does not give transactional atomicity across
workloads, record and pointer. Step 6 defines *valid* states and makes invalid
ones detectable; how strongly transitions between them are guaranteed is
FEAT-066's decision (ordered apply + verification, server-side apply, git-commit
atomicity in GitOps mode, or an explicit lease protocol).

## Step 7 — the command-level behavioural seam (2026-09-13)

Three cases, and the **order** is part of the contract: the logs backend must not
participate until identity validation *and* namespace validation have succeeded.

```text
input string
   ↓
Release_id.of_string
   ├─ invalid → malformed release-id error        (store never consulted)
   └─ valid
        ↓
      release-store lookup
        ├─ absent  → "release <id> is not known in target <t>"
        └─ present → query the configured logs backend by exact release label
```

**The third case is the one most likely to be got wrong:**

```text
unknown release     = no release record exists          → error
known release, no logs = record exists, query is empty  → success, empty result
```

"No logs" is not "no release". They stay distinct, and the distinction matters
after a rollback, for short-lived jobs, after log-retention expiry, and for a
release that never took traffic. A known release whose query returns nothing is a
*valid empty answer*, not a failure — collapsing the two would make Sol report
"unknown release" for a release it is simultaneously listing in `sol releases`.

## The strengthened step-6 invariant

```text
release_id = X
  implies
exactly one valid canonical release record for X
```

That is stronger than "records are immutable": if `sol-release-r-abc` exists with
content that does not correspond to `r-abc`, that is **corruption to report**,
never something to update into shape. Combined with a pointer whose payload is
only a `release_id`, there is exactly one authoritative description of a release
and no second copy that can drift.

## On guarantees (lesson recorded here so it is not relearned)

Do not name a weaker property as a stronger one. "Atomic" was corrected above to
the invariant that is actually held (*the pointer must not advance independently
of the desired release state*), because a multi-object apply gives no
transactional atomicity. The same discipline applies to step 7's error wording
and to the retention rule: Sol's vocabulary should only claim what the substrate
actually provides.

## Validating a record: check both directions (2026-09-13)

The step-6 invariant has two halves, and only checking the first is a trap:

```text
name direction     metadata.name == "sol-release-" ^ release_id
content direction  the stored record is the canonical content for that release_id
```

A correctly *named* record can still be corrupt, stale, hand-edited, or the
product of a bug, and it would pass a name-only check. So `sol-release-r-x` must
not be trusted merely because it is called `r-x`.

This does **not** mean recomputing release identity from the stored record on
every hot path. It means there is a validation path (and a test invariant) that
recomputes the identity from the record's content and compares — so the two
directions are checked somewhere real, and corruption is *reported* rather than
silently accepted, or worse, silently reconciled.

Note the coupling this creates: validating content means the record must carry
enough resolved facts to rederive the id (image, config, secret references,
scaling, environment), which is more than the minimal pointer carries — and
that asymmetry is the point. The record is the authoritative description; the
pointer is a claim about which one is selected.

## 5b fan-out, mapped (2026-09-13)

Reconnaissance done; the change is narrower than the render library suggested.
Three renderer entry points reach the taxonomy labels, and nothing else does:

```text
sol_cli_manifest_yaml.ml
  render_taxonomy_labels      <- drop ~image, take ~release_id : Release_id.t
  deployment_doc   (svc+worker)  <- add ~release_id, pass through
  rollout_doc      (canary/bg)   <- add ~release_id, pass through
  cronjob_doc      (fn)          <- add ~release_id, pass through

sol_cli_deployment_render.ml
  render_spec                    <- add ~release_id (it already takes ?image)
  (its three calls into the above)

callers of render_spec
  sol_cli_executor.ml  x3  (run_plan has plan.release_id; local/emit need it passed)
  test_deployment_phases.ml x1
```

So the id enters once at the executor boundary from `plan.release_id` and fans
out only inside the render library — one labelled parameter, no new context type
(one fact is a parameter; a context earns its name when several facts share a
lifetime).

Two mechanical notes for the implementer:

- `render_taxonomy_labels` **loses** `~image` rather than gaining a second
  parameter: the image tag is already `container.image`, and re-emitting it as a
  label imports the unbounded-cardinality problem into Loki's label space.
- `render_spec` already carries `?(image = "")`, so the image path is unrelated
  and must keep working; only the *label* comes from the release id.

`Sol_cli_executor.local` and the emit path take a bare spec (used by `sol up`'s
per-service apply and `sol deploy --emit-to`), so they need `~release_id` from
their callers — both of which already hold the plan, so this is passing a value
that already exists rather than deriving a second time.

## Completion notes (2026-09-13)

Landed the release half of the model: steps 5b, 6 and 7.

**Premise verified before starting.** Re-checked the ticket's "What already
exists" against the tree: `render_taxonomy_labels` still derived `release` from
`release_of_image`, `Sol_cli_release.of_plan` still minted `<timestamp>-<commit>`,
and `sol logs` had no `--release`. All three were stale in the direction the
ticket predicted — the work was still missing.

### 5b — the label is `plan.release_id`

- `render_taxonomy_labels` drops `~image` and takes `~release_id : Release_id.t`,
  written verbatim (label-safe by construction); the other taxonomy values still
  go through `sanitize_label_value`. `release_of_image` is deleted.
- `deployment_doc`/`rollout_doc`/`cronjob_doc`, `render`/`render_spec`,
  `Sol_cli_executor.local`/`gitops`, `apply_service_manifest`, and the
  diagnostics renderer take `~release_id`; `run_plan`,
  `rendered_manifests_of_plan`, `cmd_up` and the `--emit-to` path pass
  `plan.release_id`. The abstract type is kept through the whole render path —
  `to_string` is called only at the YAML edge.
- The deploy event's `release` field follows the same identity, so the deploy
  marker and the manifest labels describe one release.
- **Recon correction:** the mapped fan-out undercounted. Besides the three
  `render_spec` calls in `sol_cli_executor.ml`, `render_spec` is also called by
  `Sol_cli_release_inspection.rendered_manifests_of_service` and by
  `test_manifest_render.ml`'s helper, and `cmd_deploy.ml` read
  `release_of_image` directly. All were updated in the same pass.

### 6 — the record is the content-addressed artifact

- `Sol_cli_release` is a pure function of the released content: `of_plan`
  consumes `plan.release_id` (never recomputes it), the body is exactly the facts
  that rederive it, and `created_at`/`git_commit`/`git_dirty`/`target`/`mode`/
  `requested_scope` are gone. Provenance is a FEAT-070 hand-off.
- `content_of_record`/`derived_release_id`/`validate ~name` check the invariant
  in both directions; `parse_kubectl_list` validates on the read path, so a
  correctly named but corrupt record is not surfaced as a release.
- Serialization is deterministic (workloads and map-like pairs canonically
  sorted) and the pointer payload is `release_id` only. `sol deploy --emit-to`
  writes `sol-release-<id>.yaml` and `sol-current-release.yaml` into the bundle;
  `sol releases` shows ID / ENV / WORKLOADS.
- Tests prove the artifact-layer promise: same content ⇒ same id ⇒ byte-identical
  record, including two plans that differ only in requested scope.

### 7 — the query

- `sol logs --release <id>` filters by the exact `release` label. The three
  outcomes are ordered and distinct: malformed id fails in `of_string` before the
  release store or cluster is touched; a well-formed id with no record fails
  naming the target and recent releases; a known release with no lines is an
  empty success, never reported as unknown.
- Namespace validation (when `--scope` narrows) runs before the store, and the
  store before the logs backend. `Sol_cli_logs.release_query` is a pure
  classifier, so the order and the built selector are asserted without a
  backend: `{release="<id>"}`, or `{namespace=…,app=…,release="<id>"}` when
  scoped. `Sol_cli_loki` gained a raw-LogQL query form; the service-scoped form
  delegates to it.

### Deviations and hand-offs (deliberate)

- **Pointer name.** The bundle file is `sol-current-release.yaml` per the design,
  but the ConfigMap keeps the workspace-scoped `sol-release-current-<workspace>`
  name: it lives in the shared `default` namespace, so a fixed name would collide
  across workspaces.
- **Config values are stored, secret values are not.** The record must carry
  enough to rederive the id, and the content projection hashes config key *and*
  value; secret *references* are stored and secret values remain unrepresentable.
  FEAT-067's "keys not values" holds for secrets; for non-secret config the id
  depends on the value.
- **Metrics stay bounded.** `release` is not added as a Prometheus label; the
  correlation mechanism is documented in `docs/architecture/observability-design.md`.

### Demo / example coverage

A runnable demo cannot exercise `sol logs --release` (it needs a live cluster
plus Loki), so per the coverage rule this ticket's user-facing surface is covered
by docs and tests instead: the observability identity table, `docs/guides/TUTORIAL.md`
(`sol releases` shape, `sol logs --release`), the `sol logs` / `--emit-to`
sections of `docs/architecture/devops-pipeline.md`, the substrate contract's
GitOps section, and `docs/planning/WORK_SUMMARY.md`. New tests: `test_release`
(record shape, both-direction validation, same-content determinism),
`test_logs` (`release_query` outcomes and selectors), `test_loki`
(`query_range_argv_logql`), plus the updated `test_manifest_render` /
`test_deployment_phases` / `test_executor` release-label and bundle cases.

### Verification

`dune build`, `dune fmt` (clean), and the full `dune test` suite pass; the
pre-commit hook's unit run passes on each commit.
