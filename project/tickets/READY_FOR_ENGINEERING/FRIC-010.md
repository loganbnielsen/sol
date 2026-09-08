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
