---
id: FEAT-049
type: feature
severity: medium
source: DEC-014 (spend ceiling decision) — the enforcement mechanism needs an owner
---

**Depends on:** None to start (the attribution half is useful before any hosted tier exists).

Build the mechanism that makes DEC-014's spend ceiling real: per-tenant usage → cost attribution, spend alerts, and a reversible stop at the ceiling.

## Why this is not just a hosted-tier concern

Attribution is useful on its own — knowing what a workload *costs* is the difference between pricing from a spreadsheet and pricing from data, and it is the prerequisite for every other part of this. The stop mechanism only matters once Sol hosts something, but the metric does not.

## Scope

1. **Per-tenant spend attribution.** Usage (egress, request volume, CPU/memory time, storage) → money, using the per-tier unit costs from INFRA-006. Surfaced as a metric (`sol_hosted_spend_dollars_total{customer=…}`) so it can be alerted on like any other application metric, per DEC-014 — not a bespoke billing path.
2. **Alert rules** at 50/80/95% of the ceiling, plus a **rate-of-spend** rule (dollars/hour). The rate rule is the one that catches a runaway loop early; the percentage rules catch ordinary growth. Route through the existing Alertmanager path (OBS-043).
3. **The ceiling stop, made reversible and loud.** At the ceiling: stop the workload; raise the threshold and it returns. The stop must surface as a first-class event in `sol status` and as a notification — a silent stop reads as an outage and will be reported as one.
4. **Instantaneous limits underneath** (egress/CPU/memory) so the guarantee cannot be outrun between samples. Private implementation detail; never presented to the customer as a quota.

## Acceptance criteria

- A per-tenant spend metric exists and is alertable, with the percentage and rate rules defined.
- Stopping at the ceiling is reversible (raise threshold → workload returns) and diagnosable from `sol status`.
- Resource limits are in place so a fast runaway cannot exceed the ceiling materially between samples.
- The unit-cost table it depends on is referenced, not duplicated (INFRA-006 owns it).
