---
id: AUDIT-061
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-061/metrics-label-contracts
worktree: /home/lbendtly/Code/sun-AUDIT-061-metrics-label-contracts
---

Enforce metric label contracts and honor custom histogram buckets

**Depends on:** None.

**Description:** `Obs.register_counter`, `register_gauge`, and `register_histogram` accept `~label_names`, but the implementation ignores them and forwards any labels supplied at emit time. `register_histogram` also accepts `?buckets`, then immediately ignores it. The Prometheus backend stores whatever label set arrives and always uses `default_bounds`.

**Impact:** Callers can accidentally create unbounded Prometheus series by emitting dynamic or misspelled labels that were not declared at registration time. Histogram users cannot tune buckets for their latency domain, even though the API implies they can. This weakens performance observability and makes metric cardinality issues harder to catch in tests.

**Remediation:**

1. Store metric descriptors at registration time, including expected label names and histogram buckets.
2. Validate emitted labels against the descriptor: reject, normalize, or log mismatches consistently.
3. Pass custom histogram buckets through to the Prometheus backend.
4. Add tests for missing labels, extra labels, label ordering, and custom bucket rendering.

**Acceptance criteria:**

- `~label_names` affects runtime emission behavior and prevents undeclared label names from silently creating new series.
- `register_histogram ?buckets` renders those custom buckets.
- Existing metrics tests continue to pass after updating expectations.
- Service/worker metrics still emit their intended labels.

## Review — automated checks passed
All four remediation items implemented and tested: label filtering in register_counter/register_gauge/register_histogram, custom buckets forwarded via Histogram (value, buckets) variant, obs_prometheus.ml uses custom bounds when non-empty, obs.mli updated, and three new obs-eio tests plus one new obs-prometheus test all green.
