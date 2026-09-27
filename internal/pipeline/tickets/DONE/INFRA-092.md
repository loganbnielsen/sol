---
id: INFRA-092
type: bug
severity: medium
source: GCP qualification Attempt 14 (2026-09-26)
---

# INFRA-092 — classify admission denials directly, and capture the bindings after the prerequisites

**Depends on:** None.

Two harness gaps that Attempt 14 exposed. Neither changes product behaviour.

## 1. The classifier read a provider admission denial as ambient scheduling

Attempt 14's failure signature is `admission webhook "warden-validating.common-webhooks.networking.gke.io"
denied the request: GKE Warden rejected the request` with `autogke-disallow-hostnamespaces` /
`autogke-default-linux-capabilities` violations. `classify_fnd0010` answered `SCHEDULING_AMBIENT`,
because it has no rule for that signature and fell through to ambient Kubernetes symptoms —
the pattern the operator has flagged twice now: a *direct* failure signature must outrank ambient
evidence.

## 2. The provisioner bindings are captured only on the success path

Attempt 14's prerequisites phase succeeded, which is the point at which the provisioner
RoleBindings and ClusterRoleBinding exist, but the capture is attached to `capture_ready_evidence`,
so nothing was recorded. FND-0061's remaining inference therefore stands even though the objects
were live. Capture them after the prerequisites phase, where they first exist.

## Remediation

1. Add an admission-denial classification (`ADMISSION_DENIED_AUTOPILOT` or similar) matching
   `warden-validating`/`GKE Warden rejected` and the `autogke-` policy prefixes, ordered *before*
   the ambient scheduling fallback, with the violated policy names quoted.
2. Move (or duplicate) `capture_provisioner_bindings` so a successful prerequisites phase captures
   the objects, and assert it in the harness suite's pre-platform/prerequisite scenarios.

## Acceptance criteria

- A stub scenario whose captured evidence carries the Warden signature classifies as the admission
  denial, not as ambient scheduling.
- A run that completes the prerequisites but fails later still carries the binding objects in its
  bundle, with both subjects visible on the single objects.

## Completion notes (2026-09-26)

Both gaps closed. The classifier now answers `ADMISSION_DENIED` for the cluster's own admission
webhook refusing a manifest (`warden-validating`, `GKE Warden rejected`, `autogke-`), ordered ahead
of the ambient scheduling fallback it used to fall through to — Attempt 14's direct provider refusal
was classified `SCHEDULING_AMBIENT`. The provisioner bindings are now captured on the *failure* path
as well as on success (`capture_provisioner_bindings` runs with the failure captures), because those
objects exist from the prerequisites phase onward and Attempt 14's prerequisites succeeded while its
platform apply did not.

Evidence: `test-live-qual.sh` grows to **144 assertions, 0 failures**, including a stub case where an
admission denial coexists with ambient scheduling symptoms and must classify as the denial, and an
assertion that a failed install still reads the binding objects.
