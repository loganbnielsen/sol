---
id: REFAC-153
type: refactor
severity: medium
title: Make embedded state handling visible as explicit phase pipelines
source: Logan code review (2026-09-27), generalized from REFAC-146
---

Make embedded state handling visible as explicit phase pipelines

**Depends on:** None.

**Premise verified (2026-09-27):** `Kafka_service_retry_topics.consume` on
`origin/main` at `52c01e21` embeds validation, provisioning, two consumer lifecycles,
source/retry state transitions, relay shutdown, and error arbitration inside one
controller. Manual style-audit seeds found comparable nested state handling in
`sol_jobs.ml`, `sol_cli_rollout_diagnosis.ml`, `auth_internal.ml`, and cloud lifecycle
code; each requires caller/state-flow tracing before it is a finding.

## The principle — visible phase pipelines

Stateful orchestration should make its phases and transition values visible at the top
level. Decode/validate, decide, execute, reconcile, and render/log are different jobs.
When their transitions are buried in nested loop handlers or callbacks, policy is hard
to test independently and sibling paths drift.

Do not turn a short exhaustive state match into a framework. Keep state local when the
whole transition is already visible; extract only phases with a real input/output
contract or duplicated policy.

## Remediation

- Audit retry/service lifecycles, job polling, rollout diagnosis, authentication refresh,
  and cloud apply/destroy orchestration for controller-sized closures or repeated state
  matches.
- For each candidate, draw the actual phase/transition sequence before editing and find
  sibling paths that must share policy.
- Extract typed transition/outcome values and one shared decision path; leave top-level
  orchestration as a short linear sequence of named phases.
- Keep logging and irreversible effects at the phase that owns them, returning outcomes
  for later reconciliation rather than hiding side effects in transformations.

## Acceptance criteria

- Completion notes inventory the named subsystem candidates with a keep/refactor verdict
  and their observed phase sequence.
- Refactored controllers read as explicit ordered phases with typed boundaries.
- Duplicated sibling-path policy is shared and directly tested.
- Shutdown, cancellation, acknowledgement, and error-priority semantics remain covered;
  no effect is reordered without an explicit behavior decision.
- Demo/example and language-parity impact are recorded per changed subsystem.

