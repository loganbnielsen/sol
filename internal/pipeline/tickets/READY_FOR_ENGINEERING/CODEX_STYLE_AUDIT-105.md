---
id: CODEX_STYLE_AUDIT-105
type: audit-finding
severity: high
title: "Restrict unauthenticated developer infrastructure to intended local access"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Restrict unauthenticated developer infrastructure to intended local access

**Depends on:** None.

**Principles:** 24, 27, 31, 33, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `platform/local/scripts/ensure-grafana.sh:52`: Docker publishes port 3000 without a host address while anonymous Admin is enabled and login disabled.
- start-redpanda.sh:21 publishes plaintext Kafka/admin/schema endpoints without a bind address.
- ensure-postgres.sh:23 publishes the default-password database similarly.
- Loki, Tempo, Prometheus, and Pushgateway helpers use the same unqualified host publication pattern.

## Mechanism and impact

These scripts advertise localhost, but their Docker invocations do not restrict publication to a local interface. Unauthenticated administration/data endpoints can be reachable from other host interfaces subject to network/firewall configuration. Anonymous Grafana Admin is a direct privileged exposure. The evidence is the generated Docker invocation; actual external reachability was not tested.

## Remediation

Bind developer host endpoints to their intended local interfaces and preserve intentional container-network access. Reconcile the PostgreSQL host-gateway client proof from BUG-129 instead of blindly changing its bind address and breaking readiness. For already-running containers, detect mismatched publication and report an actionable recreation requirement or safely reconcile it.

## Acceptance criteria

- Offline Docker argv/inspection fixtures prove intended bind addresses across maintained services.
- Localhost workflows and container-network datasource access still work.
- PostgreSQL readiness verifies the actual supported consumer endpoint after publication changes.
- Broadly published existing containers are not silently accepted as compliant.
- Document any explicitly supported remote access as an opt-in authenticated configuration.

- Demo/example: update local infrastructure startup/recreation instructions.
- Language parity: no language-parity impact: host access policy is shared.

## Existing work and scope

No open matching owner was found. This is developer/test-host exposure, not a claim that cloud ingress is unauthenticated. Preserve intentional Docker-network communication.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
