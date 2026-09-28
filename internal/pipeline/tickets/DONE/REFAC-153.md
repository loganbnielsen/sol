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

## Completion (2026-09-28)

- Rechecked the named subsystem candidates and actual sibling paths after the
  generalized audit. The table records both changed and deliberately retained flows.

| Subsystem | Observed phase sequence | Verdict |
| --- | --- | --- |
| Retry-topic service | validate/provision → create source/relay → decode → handler policy → publish/ack → source run → reconcile relay error → close | Shared policy and named runtime/phase pipeline owned by REFAC-146; its unit and live-broker checks cover ack/error priority and failed relay shutdown |
| Job polling | claim leased row → decode/handle → measure lease overrun → complete, permanent-fail or retry → next claim | Keep: existing named finalizers and lease-attempt guards make the transitions explicit; do not add a new state machine |
| Rollout diagnosis | fetch pod/cronjob/events → classify available/missing/unavailable → diagnose current run → render | Keep: exhaustive typed availability and continuous/ephemeral matches protect health semantics; nesting alone is not a finding |
| Authentication refresh | decode token → validate claims → cached key lookup → refresh only on missing key → verify signature | Keep: lazy refresh and cryptographic validation phases are already named; eager refresh would change network and security semantics |
| Cloud apply | preflight → saved plan/assertion → open window → apply → install/readiness → verify de-escalation → reconcile failure | Keep typed cloud_apply controller; REFAC-152 removes contradictory input fragments without moving effects |
| Cloud destroy | state/inventory → prepare retention guarantees → assert removal plan → reconcile/window → destroy → de-escalate → verify residue/retention | Keep typed destroy outcomes and failure priority; verification cannot become a generic finally block |
| Local run | resolve workspace/selection/recipes → report → build → launch → install interrupt handler → reap/report children | Refactor into resolve_run, report_run_start, build_services, launch_services and supervise_children; top-level dev_run is the ordered phase sequence |
| Cluster migration | resolve target/workloads → reconcile substrate → collect files/image → submit → wait → logs → report outcome → cleanup → finish | Refactor wait/report/log/cleanup/finish into named phases with the existing typed migration outcome |

- Effects stay in their original phase: source/child cancellation, build error
  short-circuiting, pipe ownership, signal registration, migration logs, cleanup,
  and final error priority were not reordered.
- A real-command test with controlled npm/node adapters proves successful build
  precedes launch, while failed build prevents launch. Existing local recipe,
  migration-job (success/unstartable/timeout), supervised-process and full CLI
  tests pass, including offline cloud lifecycle scenarios and readiness argv.
- No duplicated policy was invented to justify an abstraction; the real source/
  retry duplication is addressed by REFAC-146's shared tested record path.
- Demo/example: existing local-run examples still apply; no app-author behavior
  changes. No language-parity impact: the same OCaml/TypeScript recipe contracts
  and migration/retry conventions remain unchanged.
