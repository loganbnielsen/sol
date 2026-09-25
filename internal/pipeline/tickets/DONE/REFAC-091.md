---
id: REFAC-091
type: refactor
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Port the cloud install/destroy lifecycle to a result-returning `execute ~deps`, exiting only at the command edge

**Depends on:** REFAC-095.

**Scope update 2026-09-24:** the destroy half landed as HARDEN-004 part 2 (#462: `Sol_cli_cloud_destroy.execute ~deps`, typed inventory, bracketed cleanup). What remains is the **install half**, now stage S7 of `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`: give `cloud_init` (the ~575-line apply in `cli/sol/bin/cmd_cloud_tf.ml`) the same shape, with generic sequencing and provider inputs supplied through the capabilities introduced by the stage before it, so provider selection does not happen inside the sequence. Behaviour-preserving; not a lifecycle redesign. The acceptance criteria below that concern destroy are already met; the install-side equivalents apply.

**Finding:** FND-0047, FND-0048, FND-0044 (point 2) (`internal/pipeline/audits/findings/`).

**Sequencing:** this is step 2 of the HARDEN-004 order in `internal/pipeline/audits/HARDEN-004-handoff.md` ("The order now"). Coordinate with the HARDEN-004 owner; land it as that step, not in parallel. The typed state inventory replaces outputs-based "substrate exists" (FND-0044 point 2) and identifies guarded resources by address (FND-0048, formerly INFRA-071).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding).

## Problem

`require_terraform_success`/`lifecycle_error` `exit` from inside helpers, so finalizers do not run and cleanup is hand-threaded through `on_error` (FND-0047 is a branch that forgot). The destroy sequence cannot be tested or replayed offline.

## Remediation

Follow `cmd_rollback.ml`: a `Sol_cli_cloud_destroy.execute ~deps` (and install equivalent) returning a typed outcome, terraform/gcloud/aws injected as deps, cleanup bracketed with `Fun.protect`, one place mapping outcome → exit code. Take one state inventory at the start (shared with INFRA-068/069/071/072).

## Acceptance criteria

- Guarded resources come from real addresses (root and child modules); an empty state (no `values`) is empty, not an error; a null `deletion_protection` does not raise (FND-0048 fixtures).
- A partial-outputs state is destroyable (FND-0044 point 2).
- Offline test replays the Attempt-6 state shape through `execute` with fakes.
- No `exit` remains below the command edge in the destroy path (grep check).
- Demo/example: not applicable (internal refactor) — state in completion notes.

## Completion notes

**Premise verified (2026-09-25):** on `main @ fa3d70dc`, the Apply branch of `cloud_init`
(`cli/sol/bin/cmd_cloud_tf.ml`) was 390 lines. It ended through about 20
`lifecycle_error`/`require_terraform_success` calls, and bootstrap-window cleanup was threaded
through `on_error` arguments.

**Done (install half, plan stage S7).**
- `Sol_cli_cloud_apply.execute ~deps` runs the cloud apply as a sequence and returns
  `Applied | Apply_failed { failure; cleanup }`.
  - `failure` is `Terraform_failed` (Terraform's own text) or `Refused` (Sol's reason). The
    edge prints each exactly as before.
  - The bootstrap window opens with the cloud apply. Any failure while it is open removes it
    before returning, reusing `Sol_cli_cloud_destroy.cleanup` and `report_cleanup_evidence`.
  - The removal the sequence performs itself is never retried as its own cleanup, and
    nothing after it needs one.
- The saved plan is discarded through `Fun.protect`. The sequence selects no provider.
- The AWS whoami gate, window control and de-escalation check are chosen in `apply_deps`
  (`cmd_cloud_tf.ml`), because GCP's window lives in the platform root.
- `verify_whoami_shape` and `verify_deescalation` now return results. The exiting
  `observe_bootstrap_window` and `report_cleanup_failure` are deleted.
- `cloud_init` maps the outcome to the exit code in one place: 0, or 1 as before.
- Sizes: `cloud_init` went from 554 to 193 lines. The sequence is 208 lines and
  `apply_deps` is 173.

**Behaviour changes (both deliberate).**
- The two refusals of the observed lifecycle phase used to exit without removing the window
  (FND-0047's class). They are now ordinary failures inside it. `observed_phase` cannot
  produce those phases today, so no test input reaches them.
- A failed bootstrap-access removal is reported by the destroy path's wording, `removing the
  bootstrap access failed (<terraform's text>)`, where it used to say `(terraform exited N)`.

**Evidence.**
- `test_cloud_apply.ml` (new, 10 cases) replays the sequence through fakes:
  - the happy path, with Ready reported last and the plan discarded;
  - a failure in the window removes it, exactly once;
  - a failed removal is not retried;
  - a failure after the removal needs no cleanup;
  - a cleanup failure is reported next to the primary failure;
  - an ECR removal is refused before anything is applied, and applied once confirmed;
  - a failed cloud apply opens no window;
  - an unknown substrate fails closed;
  - CloudBootstrap is reported for a fresh target;
  - an installed platform re-enters as PlatformUpdating.
- Positive control: making `execute` never clean up fails two of those cases.
- The offline lifecycle harness exits 0. It covers the apply failure paths: the whoami gate,
  window control and readiness, including bootstrap-access removal. The full
  `dune test cli/sol/test/` passes.
- `rg -n 'exit' cli/sol/lib/sol_cli_cloud_apply.ml` matches only two comments. Positive
  control: `rg -c '\bexit 1\b' cli/sol/bin/cmd_cloud_tf.ml` finds 15, at the command edges.
- REFAC-092 dispatch: `cmd_cloud_tf.ml` went from 34 to 33.

**Not in scope, and still exiting:** the command preamble (config resolution, credentials,
the INFRA-076 operation guard, `terraform init`) and `sol cloud plan`. Both run before any
state is changed, so there is nothing to clean up. The destroy-side acceptance criteria were
met by HARDEN-004 part 2 (#462).

**Bookkeeping.**
- Demo/example: not applicable. This is an internal refactor of the cloud lifecycle.
- Language parity (DEC-022): no application-facing impact.
