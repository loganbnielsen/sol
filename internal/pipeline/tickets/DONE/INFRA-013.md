---
id: INFRA-013
type: bug
severity: high
source: upstream chart retirement 2026-09-12 — redpanda 5.9.15 disappeared from the charts.redpanda.com index
---

**Depends on:** None.

**Premise checked 2026-09-12:** `charts.redpanda.com`'s index listed only 25.3.x/26.1.x/26.2.x for the `redpanda` chart (no 5.x), and both `cmd_dev.ml` and `main.tf` still pinned `5.9.15` — so a fresh install genuinely failed while the pin was unchanged.

**Related:** FRIC-007 (the original crash-loop fix that pinned 5.9.15), FRIC-010 (the modernization evaluation that declined to bump while 5.9.15 was still installable), CODE_LAYER-008 (the cmd_dev.ml / main.tf pin-sync convention).

The pinned Redpanda Helm chart `5.9.15` is no longer in the `charts.redpanda.com` index — that repo now publishes only 25.3.x / 26.1.x / 26.2.x. `helm upgrade --install redpanda redpanda/redpanda --version 5.9.15` fails immediately with `no chart version found for redpanda-5.9.15`, so `sol local up` (and the golden-path CI job it drives) cannot install a fresh substrate at all. Every PR's golden path fails on this regardless of what it changes.

The legacy tarball still resolves at `https://github.com/redpanda-data/helm-charts/releases/download/redpanda-5.9.15/redpanda-5.9.15.tgz`, but a pin that depends on a delisted artifact is not one to keep.

## Why this is not just FRIC-010 again

FRIC-010 evaluated a bump and declined it: an in-place upgrade from v24.2.7 to a 26.x binary fails Redpanda's own logical-version check (`Attempted to upgrade from incompatible logical version 13 to logical version 18`). That is a broker-side upgrade-path constraint — Redpanda only supports stepping through intermediate releases — not a Sol configuration problem. FRIC-010's conclusion assumed 5.9.15 stayed installable, which is no longer true, so the choice it deferred has been made for us.

## Scope

1. Bump both pins (`cli/sol/bin/cmd_dev.ml` and `cli/platform/infra/base/main.tf`, per CODE_LAYER-008) to a current, supported chart: **`26.1.11`** (broker image v26.1.17). This is FRIC-010's evaluated target — one minor behind newest at evaluation time, within the supported window, and already confirmed to render cleanly against the existing `values-common.json` / `values-local.json`, including the `console.*` null-vs-schema workaround, which is still required upstream.
2. Rewrite the pin comments in both files: FRIC-007's history, why FRIC-010 declined, and why the retirement forces the bump now.
3. The golden-path CI job is the live verification: a fresh k3d install of the new chart must come up and the existing smoke assertions must pass.

## Migration note (accepted)

An existing local cluster still on v24.2.7 cannot upgrade in place; it must be recreated (`k3d cluster delete`, then `sol local up`). Accepted because nothing is live. Recorded here so a future operator who hits the vassert finds the reason rather than a mystery.

## Acceptance criteria

- `sol local up` installs the pinned chart on a fresh cluster; the golden-path job passes.
- `cmd_dev.ml` and `main.tf` pin the same version.
- The vassert-on-in-place-upgrade caveat is recorded for existing clusters.

## Completion notes

Landed 2026-09-12.

- Both pins moved to `26.1.11`: `cli/sol/bin/cmd_dev.ml` (`~version`) and
  `cli/platform/infra/base/main.tf` (`version`), per CODE_LAYER-008. The pin
  comments in both files now carry the full story: FRIC-007's crash-loop fix,
  FRIC-010's decline, and INFRA-013's forced retirement of the old line.
- **Static verification (local):** rendered `helm template` for both `5.9.15`
  and `26.1.11` against the repo's real `values-common.json` /
  `values-local.json` plus the inline `~values` sets. Both render with no schema
  errors; at `26.1.11` the broker image is `v26.1.17`, the external listener
  still advertises `localhost:9092`, schema registry is present, and the local
  profile (1 replica, 1.5 CPU) still applies. The `console.*`
  null-vs-schema workaround in `values-common.json` is still required — the
  `26.1.11` render keeps `console.enabled: false`.
- **Substrate shape change worth knowing:** the 26.x chart deploys a
  `redpanda-operator` (its own image, ServiceAccount, Role/RoleBinding) that
  manages the broker — that is the new chart architecture, not a Sol addition.
- **Live verification is the golden-path job**, which is a fresh k3d install —
  exactly the path that was broken. This PR is the fix for every currently-open
  PR's failing golden path.

**Operator note.** A local cluster still running the old broker cannot upgrade
in place (Redpanda's logical-version vassert); it must be recreated
(`k3d cluster delete sol-local`, then `sol local up`). Recorded here so the
vassert is understood rather than mysterious.

Demo/example coverage: no CLI surface change.
