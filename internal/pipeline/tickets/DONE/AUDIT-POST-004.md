---
id: AUDIT-POST-004
type: audit-finding
severity: low
source: internal/pipeline/audits/2026-09-25_cloud_lifecycle_post_audit.md
---

Destroy does not apply the previous-operation guard to the platform root

**Depends on:** None.

**Related:** INFRA-076, REFAC-091, FND-0030

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S4
("Operation state: three values, not two").

## Problem

`guard_previous_operation` (`cli/sol/bin/cmd_cloud_tf.ml:300-330`) classifies the last operation
recorded against one Terraform state as `Running`, `Resolved` or `Unresolved`. It is called:

- `:1030` — cloud root, apply;
- `:1037` — platform root, apply;
- `:1219` — cloud root, destroy;
- **never for the platform root on the destroy path**, although destroy runs platform-root Terraform
  work (`run_terraform_init_result run_log platform_dir platform_backend` at `:1265` and `:1358`, and
  the platform destroy applies inside `Sol_cli_cloud_destroy.execute`).

## Root cause

When the destroy path was restructured (REFAC-091 / REFAC-096) the cloud root's guard was carried
over verbatim, but the platform root's was not — the apply path had two guards and the destroy path
kept one. Operation records are written for both roots (`sol_cli_terraform.ml:9-16` keys by root plus
backend configuration), so the platform root has the state; the destroy path simply never reads it.

## Impact

A platform-root operation that is still running, or that ended unresolved, is not reported through
Sol's operation-state contract before destroy starts conflicting platform work. Terraform's backend
lock still prevents the conflicting mutation (so this is not an unsafe mutation), but the operator
sees a lock error instead of "an operation is still running and holds its lock; wait", and the
destroy path is asymmetric with apply.

## Remediation

Before the destroy path performs platform-root Terraform work, apply the same classification with
the non-constructive policy already established for destroy. Use the existing API; do not add a
second operation-state mechanism, and do not change `Sol_cli_supervised`.

```ocaml
guard_previous_operation
  ~constructive:false
  ~accept_unresolved:false
  ~chdir:(platform_dir provider)
  ~backend_config:(Sol_cli_cloud_lifecycle.platform_backend cloud_target)
```

Place it where the platform root is resolved for destroy (the same place the cloud-root guard runs,
or immediately before the first platform-root Terraform operation, if the platform root is only
known there). The cloud-root behaviour must not change.

## Acceptance criteria

Executable evidence for the platform root, alongside the existing cloud-root scenarios:

- **Running:** destroy recognises it, reports it through Sol's operation-state contract, and does not
  start conflicting platform Terraform work.
- **Unresolved:** destroy reports/refuses according to the established unresolved-operation policy.
- **Resolved:** destroy proceeds normally (including a graceful non-zero exit, which is `Resolved`).
- Cloud-root behaviour unchanged.
- Backend lock untouched; no force-unlock; no process killing; `Sol_cli_supervised` unchanged.
- The offline lifecycle harness gains the platform-root scenarios; existing INFRA-076 scenarios stay
  green.

## Completion notes (2026-09-25)

**Problem.** `cloud_destroy` guarded the previous-operation state of the cloud root only
(`cmd_cloud_tf.ml:1219`), while the destroy path also runs platform-root Terraform work
(`run_terraform_init_result run_log platform_dir platform_backend` at `:1265`/`:1358`, and the
platform teardown inside `Sol_cli_cloud_destroy.execute`). Apply guarded both roots (`:1030`,
`:1037`), so destroy was asymmetric.

**Root cause.** When the destroy path was restructured (REFAC-091/096) the cloud root's guard was
carried over and the platform root's was not, even though operation records are written for both
roots (`sol_cli_terraform.ml:9-16` keys by root plus backend configuration).

**Change.** One call, immediately after the cloud-root guard in `cloud_destroy`
(`cli/sol/bin/cmd_cloud_tf.ml`), with the same non-constructive policy the cloud root already gets
on destroy:

```ocaml
guard_previous_operation
  ~constructive:false
  ~accept_unresolved:false
  ~chdir:(platform_dir provider)
  ~backend_config:(Sol_cli_cloud_lifecycle.platform_backend cloud_target);
```

No new mechanism: the same `Sol_cli_supervised` classification, the same single durable completion
model, the same policy a non-constructive command gets. The operation-state contract is therefore
now: `Running` refuses; `Unresolved` is named and destruction proceeds (a destroy constructs
nothing from the gap); `Resolved` proceeds silently — including a graceful non-zero exit, which is
`Resolved`.

**Executable evidence.**
- `internal/ci/test_cloud_lifecycle_offline.sh` gains three platform-root scenarios after the
  existing cloud-root INFRA-076 ones, with the cloud root's record deliberately left `Resolved`
  first so a refusal can only have come from the platform root:
  - `Running` (live pid): destroy refuses with `is still running and holds its lock`, and the run
    log shows no Terraform invocation at all;
  - `Unresolved` (`signaled 9`): destroy proceeds and names
    `the previous Terraform operation against this state is unresolved`;
  - `Resolved` (`exited 0`): destroy proceeds and does *not* name an unresolved operation.
- **Mutation control:** with the new guard call removed, the harness fails at
  `AUDIT-POST-004: a destroy raced a running platform operation` (exit 1); restored, it exits 0. The
  scenario can fail, so it is not vacuous.
- Cloud-root behaviour unchanged (its three INFRA-076 scenarios still pass); no force-unlock, no
  process killing, `Sol_cli_supervised` untouched.

**Canonical merge SHA.** The squash commit that moved this ticket to `DONE/`; recover it with
`git log --oneline -1 -- internal/pipeline/tickets/DONE/AUDIT-POST-004.md`.

- Demo/example: not applicable (cloud lifecycle internals).
- Language parity (DEC-022): no application-facing impact.
