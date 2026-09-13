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

1. **Mint the release id once, before render.** The label is rendered into the pod template at apply time; the record is written after. For the two to agree, the id must be created *before* rendering and carried to the record write, not generated separately at record time. This is the load-bearing design point of the ticket.
2. **Make the taxonomy `release` label carry that id** rather than the image tag (which remains available as its own fact — do not lose the image tag just to reuse the word).
3. **Add the query:** `sol logs --release <id>` (and the same for `sol status`/`sol open` links) adds `release="<id>"` to the LogQL/Grafana selector, so `sol releases` → `sol logs --release <id>` is a real workflow.
4. **Metrics: do not add release as an unbounded Prometheus label.** Releases increase forever, so a raw `release=` dimension accumulates cardinality without bound. Metrics correlate through deployment metadata and/or a bounded *current-release* info metric. Logs and traces are the surfaces that take the label directly. Record whichever mechanism is chosen rather than leaving it implicit.

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

## Open decisions (blocking implementation)

### 1. Is the id *minted* (per deploy event) or *derived* (per released content)?

This is the one thing worth settling before writing code, because it decides
whether `Release_id` has a `create : unit -> t`-shape or a
`derive ~inputs -> t`-shape, and it has an operational consequence that is easy
to miss:

**A minted-per-deploy id changes the pod template on every deploy, and therefore
forces a rollout every deploy** — including a no-op redeploy, and including a
GitOps sync that would otherwise be an empty diff. With a content-derived id,
"deploy the same thing twice" is a no-op, which is what makes `--emit-plan-to` +
Argo idempotent.

Proposed split, if we take derived:

- **`Release_id` = identity of the released content** — a pure function of the
  plan (workspace, env, and per-workload image + config + secret *references* +
  scaling). Stable across re-deploys; trivially testable.
- **The release record = the deploy event** — `created_at`, `git_commit`,
  `git_dirty`, who/what triggered it. FEAT-067 already carries these.

That makes "same content ⇒ same identity" true, and keeps event history in the
record where it belongs. Known limitation to state explicitly: the id covers
secret *references*, not secret material (DEC-018), so rotating a secret value
does not by itself change the release identity.

### 2. How does GitOps/`--emit-plan-to` mode record the release?

Today the record is written by `sol deploy` after a direct apply. In emit mode
Sol renders manifests and Argo applies them, so nothing writes a record — the
labels would say `release=r_x` while `sol releases` has no `r_x`. To keep the
"same ID everywhere" invariant true in both modes, the record should be part of
the emitted bundle (a ConfigMap manifest alongside the workloads), so applying
the bundle records the release. That also makes the record a deployed artifact
rather than a CLI side effect, which is closer to DEC-018's "the release record
is authoritative".

### 3. Does the id belong in the emitted plan JSON / `--emit-plan-to` output?

Probably yes — the emitted artifact is a release intent, and its id is the thing
a reviewer and a later rollback both need. Flagged because it changes the emitted
plan shape and any golden assertions over it.

## The rule, sharpened

> Give important identities and environmental facts a single authoritative
> representation, establish them before side effects, and pass them downward
> rather than rediscovering them.

Adding the criterion for *what groups together*, which REFAC-089 just taught:
group by **lifetime and authority**, not by count. `cluster`/`workspace`/`env`
share the lifetime of one execution; `mode` lives for one call; a release id
lives for one plan. Facts that share a lifetime belong in one value; facts that
do not, must not be flattened into one.
