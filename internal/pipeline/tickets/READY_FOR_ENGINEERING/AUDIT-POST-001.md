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

## Completion notes (required)

- Problem / root cause / change / executable evidence / canonical merge SHA.
- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
