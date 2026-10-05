---
id: CODEX_STYLE_AUDIT-104
type: bug
severity: medium
title: "Use truthful bounded readiness outcomes across local service setup scripts"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Use truthful bounded readiness outcomes across local service setup scripts

**Depends on:** None.

**Principles:** 6, 15, 20–24, 33, 35–37 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `platform/local/scripts/ensure-tempo.sh:37`: healthy probe breaks the loop, then unconditionally prints failure and exits 1.
- ensure-prometheus.sh:34 and ensure-pushgateway.sh:27 exhaust probes but print endpoints and exit 0.
- ensure-grafana.sh:61 proceeds to provisioning after exhaustion. Several existing-container branches skip health observation.
- HTTP probes omit per-request connect/total bounds.
- Offline fake docker/curl reproduction: healthy Tempo => exit 1; permanently failed Prometheus/Pushgateway probes => exit 0. No real service/container was started.

## Mechanism and impact

Duplicated controller logic disagrees on success and failure. Retry counts without bounded probes do not establish a deadline. Setup/test callers can proceed with unavailable infrastructure or reject infrastructure that is ready.

## Remediation

Use one modest shared bounded readiness policy with service-specific probes. Probe reused as well as new containers, advance only after successful readiness, and preserve the final failed observation on timeout. Apply it to the maintained helpers including database query bounds where relevant; keep intentional optional datasource provisioning distinct.

## Acceptance criteria

- Immediately healthy, eventually healthy, permanently unhealthy, hanging probe, and reused unhealthy fixtures have correct outcomes.
- Healthy Tempo reaches post-readiness network reconciliation.
- Exhaustion suppresses ready/success claims and returns nonzero.
- Every probe has a real wall-clock bound; declared overall timeout remains meaningful.
- Existing legitimate network/database consumer checks remain covered.

- Demo/example: update maintainer setup instructions and demonstrate each helper success/failure contract.
- Language parity: no language-parity impact: shared maintainer infrastructure.

## Existing work and scope

REFAC-026's completed criteria promised timeout failure; BUG-129 explicitly excluded these general readiness gates. Product k3d forward readiness is a separate controller ticket.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
