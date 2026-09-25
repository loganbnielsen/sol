---
id: AUDIT-POST-001
type: audit-finding
severity: medium
source: internal/pipeline/audits/2026-09-25_cloud_lifecycle_post_audit.md
---

AWS identity model and ARN parsing are exported from the generic lifecycle

**Depends on:** None.

**Related:** REFAC-096, REFAC-097, DEC-040, AUDIT-POST-007

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`,
§ Decisions 2 and § S8.

## Problem

`Sol_cli_cloud_lifecycle` — the generic lifecycle module — exports an AWS-native identity model:

- `type whoami_identity = { arn; canonical_arn; username; source }`
  (`sol_cli_cloud_lifecycle.ml:1152-1161`, exported at `.mli:340-348`);
- `whoami_identity_of_json` (`:1180`), which parses the EKS authenticator's `SelfSubjectReview`
  response, including its one-element-array quirk (`:1163-1178`);
- `index_of_substring` (`:1240`), `role_name_of_arn` (`:1253`) — ARN parsing that specifically
  understands `...:assumed-role/<role>/<session>`;
- `principal_role_name` (`:1281`) and `principal_matches` (`:1317`).

## Root cause

The DEC-040 de-escalation machinery (the whoami shape gate, the control capture and the
principal comparison) was moved to `Sol_cli_aws_cluster` by REFAC-096, but the *identity model and
its parsers* were left behind in the generic module and continued to be called from AWS code. It
predates the simplification program (present at baseline `c91af060`, lines 1386-1530), so no stage
was scoped to remove it: S5b's "delete ARN parsing" clause was qualified "where used only by that
verification", and this parsing is used by a surviving Sol guarantee instead.

The generic module's own header (`sol_cli_cloud_lifecycle.ml:30-36`) states the intended invariant:
"Provider-specific *identity* is deliberately absent: an AWS target names a role ARN because that is
how an AWS caller assumes the provisioner, while a GCP target names nothing…". The exported type
contradicts it.

## Impact

A provider-native identity concept is part of a generic module's public interface. A reader (or a
future provider author) sees a generic `whoami_identity` and must decide whether it applies to them;
GCP never produces one. Nothing behaves incorrectly today — the only consumer is AWS — but the
boundary the program exists to establish is not yet true of this module.

## Remediation

Move the AWS identity representation and its parsers into the AWS provider implementation
(`Sol_cli_aws_cluster`, or a small AWS-specific module if that keeps the cluster module readable —
there is no cross-provider reuse reason today, so no new shared module is justified).

- Move `whoami_identity`, `whoami_identity_of_json`, `single_string_of_json`, `index_of_substring`,
  `role_name_of_arn`, `principal_role_name`, `principal_matches` out of `Sol_cli_cloud_lifecycle`.
- Remove them from `sol_cli_cloud_lifecycle.mli`.
- Do **not** introduce a generic identity variant (`Aws_identity | Gcp_identity`) — that recreates
  the problem under a new name.
- Decide the de-escalation verdicts (`deescalation_verdict`, `deescalation_transition`,
  `permission`/`capability` machinery) from actual dependencies: their inputs are kubectl
  `SelfSubjectReview`/`can-i` probes. If the only consumer is AWS and the semantics are
  AWS-window-shaped, move them too; if the probe/verdict combination is provider-neutral with a
  second plausible consumer, they may stay, but then say so in the module header instead of the
  current statement that identity is absent.
- AWS behaviour must be byte-for-byte unchanged; the existing de-escalation tests must stay green.

## Acceptance criteria

- No ARN/native-AWS identity type is exported from `Sol_cli_cloud_lifecycle.mli`.
- `Sol_cli_cloud_lifecycle` contains no ARN parser (`rg -n 'arn|assumed-role|canonical' cli/sol/lib/sol_cli_cloud_lifecycle.ml` returns nothing identity-shaped).
- AWS de-escalation behaviour unchanged; `test_cloud_lifecycle.ml` de-escalation and whoami cases green.
- An executable check prevents the knowledge from drifting back: extend the provider-dispatch guard
  (or add a small check) so an `arn`/identity-shaped declaration in a generic module is visible to CI,
  with a positive control.

## Completion notes (2026-09-25)

**Problem.** `Sol_cli_cloud_lifecycle` exported an AWS-native identity model:
`type whoami_identity = { arn; canonical_arn; username; source }`, `whoami_identity_of_json`,
`single_string_of_json`, `index_of_substring`, `role_name_of_arn`, `principal_role_name`,
`normalize_role_arn`, `principal_matches`, and the `credential_assumption` /
`refusal_is_deescalation` pair. The only product consumer was `Sol_cli_aws_cluster` (plus tests),
and it contradicted the module's own header ("Provider-specific *identity* is deliberately absent")
and plan decision 2.

**Root cause.** REFAC-096 moved the DEC-040 *probes* into the AWS cluster but left the identity model
and its parsers behind, and no stage was scoped to remove them: S5b's "delete ARN parsing" clause was
qualified "where used only by that verification", and this parsing is used by a surviving Sol
guarantee instead. It predates the simplification program (present at baseline `c91af060`).

**Change.** ~220 lines moved into `Sol_cli_aws_cluster`, which is where the mechanism is produced:
the EKS-specific `status.userInfo.extra` array shape, `canonicalArn` preference, one-element-array
strictness, ARN role-name extraction, path normalisation, the strict canonical-ARN comparison, and
the credential-assumption check. Removed from `Sol_cli_cloud_lifecycle.mli`, with a pointer note
saying where they went and why.

**What deliberately stayed.** `deescalation_principal`, `deescalation_verdict`, `capability`,
`capability_answer`, `capability_answer_of_can_i_output`, `deescalation_transition` and
`deescalation_verdict_to_string` remain in the generic module: their inputs are `kubectl auth
can-i` / `whoami` probe answers and a principal *label*, with no provider-native identity in the
types, so they are the provider-neutral verdict layer the AWS mechanism feeds. Decided from the
dependencies, not the naming.

**Executable evidence.**
- `dune build`; `dune test cli/sol/test/ --force` green, including every de-escalation, whoami-shape,
  principal-comparison and credential-assumption case (retargeted from
  `Sol_cli_cloud_lifecycle.*` to `Sol_cli_aws_cluster.*`); the offline lifecycle harness green,
  including its DEC-040 canary (the shape gate still reports `whoami shape: parsed`), so the
  behaviour is unchanged end to end.
- **Drift guard.** `check_provider_dispatch.sh` gains a declaration-level rule over the generic
  modules: a `type whoami_identity` / `credential_assumption`, one of the parser `let`s, or a
  `canonical_arn :` field is refused. Which modules count as generic is now *derived* -- the guard
  reads the provider list from `sol_cli_provider.ml` (as `check_destroy_completeness.sh` does for its
  target roots since HARDEN-005) and excludes `<provider>_<kind>` implementations, so a provider
  added later is admitted without editing the guard. The count is zero today, so it is zero-tolerance
  rather than a ratchet. `test_provider_dispatch_check.sh` gained two reject cases (a generic whoami
  parser, a generic `canonical_arn` field), an accept case (the same declarations inside
  `sol_cli_aws_cluster.ml`), and a control for a *third* provider's implementation.
- **Mutation control.** Re-adding `let whoami_identity_of_json` to `Sol_cli_cloud_lifecycle.ml` makes
  the guard fail with `declares provider-native identity machinery`; removed, it passes. The rule can
  fail, so it is not decoration.

**Canonical merge SHA.** The squash commit that moved this ticket to `DONE/`; recover it with
`git log --oneline -1 -- internal/pipeline/tickets/DONE/AUDIT-POST-001.md`.

- Demo/example: not applicable (cloud lifecycle internals).
- Language parity (DEC-022): no application-facing impact.
