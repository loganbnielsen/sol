---
id: FRIC-010
type: dogfood-finding
severity: low
source: FRIC-007 round-1 adversarial review — the reviewer independently reproduced and confirmed the FRIC-007 fix but flagged the chosen Redpanda version as needlessly conservative
---

**Depends on:** None.

Evaluate a deliberate Redpanda version upgrade past 5.9.15/v24.2.7 (the minimal fix FRIC-007 landed) to a current, actively-supported release.

## Why this is separate from FRIC-007

FRIC-007 fixed a crash-loop bug by bumping Redpanda from chart 5.8.12 (image v24.1.8, predates JSON Schema Registry support entirely) to chart 5.9.15 (image v24.2.7) — deliberately the smallest version jump that provably has the fix, chosen so the fix could be fully verified end-to-end (a real live golden-path run: `sol dev up` → `sol up` → `sol migrate` → `sol status` → HTTP → Kafka → worker → notification) without also absorbing the risk of unrelated breaking changes from a larger version jump.

FRIC-007's own adversarial review (round 1) independently reproduced and confirmed every technical claim in that fix, but raised a fair point: as of this ticket's filing, chart 5.9.15/image v24.2.7 was published 2024-12-03 — roughly two years old, with ~390 chart releases and multiple Redpanda minor lines (24.3, 25.1, 25.2, 25.3, 26.1, 26.2) released since. This repo's own `CLAUDE.md` states a pre-alpha preference for "the correct design over the stable one," and there's no backwards-compatibility reason to sit on the oldest version that "just barely" works.

The reviewer's point is valid, but resolving it inside FRIC-007 would have meant either (a) delaying an active production-crash-loop fix to fully re-verify against a much newer, multi-major-version-jump target, or (b) picking a newer version without matching verification rigor. Both are worse than landing the narrow, fully-verified fix now and evaluating a deliberate modernization separately, with its own dedicated verification pass — the same reasoning already used to split FRIC-009 (CI regression check) out of FRIC-007 rather than bundling it.

## Scope

1. Check the current latest stable `redpanda/redpanda` Helm chart version and decide on a target — likely not the bleeding-edge release (minimize "too new, unbaked" risk) but something recent and within the actively-supported release line, per Redpanda's own support policy.
2. Diff the chart's `values.yaml`/`values.schema.json` between v24.2.7 and the target version for any other breaking changes beyond what FRIC-007 already found (the `console.ingress.className`/`console.service.targetPort` null-vs-schema mismatch, worked around in `platform/components/redpanda/values-common.json` — confirm whether that workaround is still needed at the new target version, or whether it's been fixed upstream).
3. Re-run the full live golden-path verification FRIC-007 did (not just `helm template` rendering) against the new target: `sol dev up`, `sol up`, `sol migrate`, `sol status`, HTTP → Kafka → worker → notification round-trip.
4. Update both `cli/sol/bin/cmd_dev.ml` and `platform/infra/base/main.tf` together, per the existing CODE_LAYER-008 sync convention.

## Not in scope

- Not urgent/blocking — v24.2.7 is a real, working, fully-verified fix for the actual crash-loop bug. This is deliberate technical-debt paydown, not a follow-up bug fix.
- Not a general "keep Redpanda always on latest" policy or automation — a one-time deliberate jump, evaluated and verified like any other dependency bump.

## Evaluation result (2026-09-08): do not adopt — recommend closing without a version change

Followed the ticket's scope against a real live cluster (this environment has a running k3d cluster with an existing Redpanda 5.9.15/v24.2.7 deployment and two live dogfood workspaces).

1. **Target chosen:** `redpanda/redpanda` chart `26.1.11` (app `v26.1.17`) — one minor line behind the newest release (`26.2.x`), 11 patch releases deep on its own minor, within Redpanda's actively-supported window. Deliberately not bleeding-edge.
2. **Static compatibility check:** `helm template` rendered cleanly against this repo's existing `values-common.json`/`values-local.json` with no schema errors. Diffed `values.yaml`/`values.schema.json` between v24.2.7 and 26.1.11: the `console.ingress`/`console.service` null-vs-schema mismatch FRIC-007 worked around is **still present upstream** at 26.1.11 — the `values-common.json` workaround (`console.enabled: false`, explicit `ingress.className`/`service.targetPort`) is still required, unchanged.
3. **Live verification — this is where it failed.** Bumped both `cmd_dev.ml` and `platform/infra/base/main.tf` to `26.1.11` and ran `sol dev up` against the real cluster to perform an in-place `helm upgrade` of the existing broker (not a fresh install). The upgrade failed: the new binary crash-loops on startup with

   ```
   ERROR ... assert - Assert failure: (src/v/features/feature_table.cc:883) 'false'
   Attempted to upgrade from incompatible logical version 13 to logical version 18!
   ```

   This is Redpanda's own internal cluster-metadata versioning refusing the upgrade — a hard `vassert` crash, not a config or values problem. Redpanda enforces sequential upgrades through its internal "logical version" scheme; the v24.2.7 → v26.1.17 jump (5 logical versions, ~18 months, 6 minor lines) is too large to apply in place. This reproduced deterministically and is a genuine Redpanda-side constraint, not anything specific to Sol's configuration.
4. **Recovery:** `helm rollback redpanda 3 -n redpanda` restored the cluster to the working 5.9.15/v24.2.7 state (`STATUS: deployed`, pod healthy, schema registry responding `200`). Both live dogfood workspaces (`charge-svc`, `notify-worker`) were undisturbed throughout — verified still `Running` after the rollback. Code changes to `cmd_dev.ml`/`main.tf` were reverted; **the version pin in `main` is unchanged.**

**Why this changes the recommendation:** the ticket's own text ("evaluated and verified like any other dependency bump") anticipated needing verification rigor, but assumed the risk was scoped to values/schema compatibility. The real risk is Redpanda's upgrade-path support window itself — any Sol operator (dev or production) currently running on the existing pin who pulls a future Sol release with this jump baked in would have their **running cluster crash-loop on the next `sol dev up`/`terraform apply`**, with no automatic recovery (a human has to know to `helm rollback`). That's a materially worse outcome than the ticket anticipated, for a change explicitly filed as non-urgent technical-debt paydown.

**Recommendation:** do not adopt this jump. If a modernization pass is wanted later, it needs one of:
- A verified **sequential** upgrade chain (v24.2.7 → v24.3.x → v25.1.x → v25.2.x → v25.3.x → v26.1.x, each hop tested against a real running cluster the way this one was), which is meaningfully more effort than a single-ticket scope, or
- Accepting that adopting a distant target requires **documented cluster recreation** (tear down and redeploy Redpanda, losing topic data) rather than an in-place upgrade — a real operational/data-loss tradeoff that would need to be called out prominently in release notes, not silently shipped as a routine version-bump commit.

Given this is explicitly low-severity, non-blocking paydown, recommend closing this ticket as evaluated-and-declined rather than opening a larger sequential-upgrade project speculatively — revisit if/when there's an actual reason to move off v24.2.7 (e.g., a real bug or feature gap in the current pin), at which point the sequential-hop path above is the way to do it safely.
