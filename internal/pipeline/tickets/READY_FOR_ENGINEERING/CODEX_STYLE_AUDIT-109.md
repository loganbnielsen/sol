---
id: CODEX_STYLE_AUDIT-109
type: infra
severity: low
title: "Declare reproducible image references for maintained integration infrastructure"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Declare reproducible image references for maintained integration infrastructure

**Depends on:** None.

**Principles:** 15, 28, 33, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `platform/local/scripts/start-redpanda.sh:25` uses Redpanda latest.
- ensure-tempo.sh:33, ensure-prometheus.sh:28, and ensure-pushgateway.sh:24 use latest.
- Grafana is already explicitly versioned; BUG-008 records a prior mutable-image compatibility failure.

## Mechanism and impact

The same source snapshot can start a different backend version on another host or after image refresh. This weakens test reproducibility and makes failures difficult to attribute. These Docker helpers are distinct from the product's shared Helm definitions; the defect is mutable test inputs, not proof of product local/cloud drift.

## Remediation

Declare intentional version/digest references for the maintained service set once and reuse them wherever those same helpers/CI services are provisioned. Keep upgrades explicit and compatibility-checked; no dependency management framework is needed.

## Acceptance criteria

- No latest/unversioned references remain in this maintained helper set.
- Helpers/CI that provision the same backend consume the same declared reference.
- Record upgrade procedure and supported compatibility expectations.
- Existing bounded readiness fixtures still pass; run relevant integration smoke when intentionally selecting versions.

- Demo/example: not an application API change; update maintainer environment documentation.
- Language parity: no language-parity impact.

## Existing work and scope

BUG-008 fixed Grafana but does not own the remaining mutable service set. No matching open owner was found.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
