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
