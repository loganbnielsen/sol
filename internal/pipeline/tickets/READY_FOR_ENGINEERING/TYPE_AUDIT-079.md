---
id: TYPE_AUDIT-079
type: refactor
severity: low
title: "Retain resolved workload identities until the local execution adapter serializes them"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Retain resolved workload identities until the local execution adapter serializes them

**Depends on:** None.

**Principles:** 1, 3, 4, 13, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/deploy/sol_cli_up_execution.ml:1` defines service_execution k8s_name and namespace as strings.
- `:49`: service_execution erases validated spec identities before build/push.
- `:93`: wait_for_service_rollout accepts both the typed service_spec and independently string-valued execution record.
- Real serialization edges are kubectl argv construction and user-facing formatting, not the execution record.

## Mechanism and impact

The execution record is an internal operation value, not a serialized report. Early conversion allows identities to be swapped or disagree with the typed spec while the compiler cannot help. This is specifically abstract Kubernetes_name erasure; rendering DTOs elsewhere need not be changed.

## Remediation

Retain resolved namespace/name types in service_execution, or eliminate redundant identities and derive them from the validated spec at the adapter edge. Convert only for argv/output formatting. Update all callers together without compatibility aliases.

## Acceptance criteria

- Internal execution identities retain the abstract validated types or have one authoritative source.
- Rollout cannot accept conflicting independently supplied identity strings.
- Serialization happens at named argv/output boundaries.
- Existing build/push/rollout callers and tests retain behavior; no new wrapper abstraction is added.

- Demo/example: not applicable: internal execution typing; record why.
- Language parity: no language-parity impact: shared CLI adapter.

## Existing work and scope

TYPE_AUDIT-078 covered deploy-event IDs, not these execution identities. Release-inspection rendering DTOs are deliberately outside this ticket.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
