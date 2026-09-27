---
id: FND-0064
type: audit-finding
severity: high
source: GCP qualification Attempt 14 (2026-09-26), revision ae47d777
---

# GKE Autopilot admission refuses the platform's component manifests

**Depends on:** None.

Live discovery, GCP qualification Attempt 14: `sol cloud apply` on a fresh GKE **Autopilot** cluster
applied the cloud root and the platform prerequisites, then the platform's Helm releases were
refused by the cluster's own admission webhook — three errors, two components, two policies:

```
[denied by autogke-disallow-hostnamespaces]:
  ["enabling hostNetwork is not allowed in Autopilot.","enabling hostPID is ...]
  with module.platform.helm_release.prometheus     (modules/platform/main.tf line 1456)

[denied by autogke-default-linux-capabilities]:
  ["linux capability 'SYS_RESOURCE' on container 'tuning' not allowed; ...]
  with module.platform.helm_release.redpanda       (modules/platform/main.tf line 314)
```

## Problem

Sol's platform declares two components whose upstream charts require a host-level privilege that
Autopilot forbids by policy: prometheus asks for `hostNetwork`/`hostPID` (its node-exporter
DaemonSet), and Redpanda's `tuning` container asks for the `SYS_RESOURCE` capability. On GKE
Autopilot the platform therefore cannot install, and the lifecycle stops before readiness — the run
never reaches `Ready`, and the storage boundary (PVCs binding) is upstream of it and untested.

## Root cause

Not a Sol bug in the sense of a defect in code: the provider is honouring its own security policy,
and the platform is asking for something that policy forbids. It is a **product configuration
decision** the defaults have never had to make: the platform was qualified against clusters that
permit these privileges, and the Autopilot case was never designed for.

## Impact

Every `sol cloud apply` on GKE Autopilot stops at the platform apply, after roughly ten minutes of
billable infrastructure, with no path to `Ready` until a decision is taken. The failure is
fail-closed and tidy — the run televerd down cleanly with no residue — but the capability gap is
real and now measured.

## Decision required (not a code fix)

Which of these is the product's answer, and on what evidence?

1. **Prometheus**: is node-exporter part of the platform's contract at all? If it is not essential,
   disabling it (or its host-access requirements) on Autopilot is a values decision. If host
   metrics are contractual, Autopilot must be declared unsupported for the production profile.
2. **Redpanda**: its `tuning` container is an upstream chart default. If the capability is genuinely
   required, the platform must either drop the tuning step on Autopilot or declare the provider
   profile unsupported for Autopilot clusters.
3. **Capability boundary**: if Autopilot is to be supported, `Sol_cli_provider_capabilities` is the
   place that says so — as a declared capability of the provider profile, never a conditional in
   generic lifecycle code.

Until this is decided, Autopilot-on-GCP should be treated as **not installable**, and the
qualification ledger should say so rather than implying the platform installs anywhere GKE runs.

## Remediation

A decision (ADR or DEC) followed by the configuration it implies, plus the harness/classifier work
in `INFRA-092`.

## Acceptance criteria

- The decision is recorded, with the Autopilot support boundary stated explicitly.
- If Autopilot is supported: a fresh Autopilot run reaches the platform apply's completion, and the
  readiness contract is exercised.
- If Autopilot is not supported: the capability declaration refuses the profile *before* creating
  billable infrastructure, with a message naming the reason.
