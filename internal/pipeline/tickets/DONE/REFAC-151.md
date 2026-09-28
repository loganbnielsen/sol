---
id: REFAC-151
type: refactor
severity: low
title: Bounded CLI commands return typed outcomes before rendering them
source: Logan code review (2026-09-27), generalized from cmd_alert and cmd_assets
---

Bounded CLI commands return typed outcomes before rendering them

**Depends on:** None.

**Premise verified (2026-09-27):** `cmd_alert.ml`'s `report_outcome` both interprets and
prints an outcome; `cmd_assets.ml` computes, renders, prints, and decides failure inside
`run`; `cmd_check.ml`, `cmd_plan.ml`, `cmd_target.ml`, `cmd_releases.ml`, and
`cmd_deployments.ml` are other bounded commands that can be reviewed against the same
operation → outcome → rendering → terminal-effect shape. REFAC-135 removed printing
from `cli/lib`, and REFAC-139 moved decisions out of four large commands, but neither
audited this remaining `cli/bin` category.

## The principle

For a bounded command whose operation finishes before output begins:

1. the operation returns structured data or a typed outcome;
2. semantic failure is decided where that outcome is built;
3. that typed outcome travels up the call chain unchanged;
4. the command entry function renders it to text at the point it prints, and owns
   stdout/stderr and exit conversion.

Do not build the output text in a helper deeper in the call chain and return it as a
string: text is built where it is printed. Do not force this shape onto progress output,
prompts, streaming logs, child-process forwarding, or other operations whose terminal
effect is part of execution. Do not add `print_*` wrappers that merely hide the effect
one function deeper.

## Remediation

- Inventory bounded commands in `cli/bin` and classify each as bounded presentation or
  inherently streaming/effectful.
- Apply the typed-outcome boundary to high-confidence bounded commands, starting with
  the `alert` and `assets` examples, and reuse existing domain outcomes/renderers.
- Put semantic decisions in `cli/lib` only when they are domain behavior; keep thin
  presentation records local when no library consumer needs them.
- Add the bounded-versus-streaming distinction to the command convention in
  `CONTRIBUTING.md`.

## Acceptance criteria

- Completion notes inventory every `cli/bin` command with a bounded/streaming verdict;
  silence is not a verdict.
- High-confidence bounded commands have directly testable operation outcomes and pure
  rendering before the controller prints.
- Streaming/progress commands retain their effects, with the reason recorded; no fake
  buffering is introduced merely to satisfy the pattern.
- User-visible output and exit codes are byte-for-byte unchanged in real-command tests.
- Demo/example: not applicable unless a changed command alters app-author behavior.
- Language parity: no impact; this is CLI implementation structure.

## Completion (2026-09-28)

- Re-derived the boundary against the reviewed branch rather than the ticket text alone.
  An earlier pass introduced `render_*` helpers that built the command's whole output
  string (and folded the failure decision into the same `(string, failure) result`) and
  passed it up to `run` to print. That is exactly the shape this ticket rejects, so those
  helpers are gone: the typed outcome travels to the command boundary, which prints.
- Extracted a pure operation only where compute was genuinely mixed with presentation:
  `cmd_assets` now has `inspect : unit -> (report, Sol_cli_exit.failure) result` and
  `cmd_check` has `inspect : scope -> (outcome, Sol_cli_exit.failure) result`, each
  carrying the semantic verdict; their `run` renders the typed fields, prints them, and
  returns the verdict. `cmd_alert` matches `Sol_cli_alert_test.outcome` at the command
  boundary and prints there, with the sending progress left before the request.
- `cmd_plan`, `cmd_releases`, and `cmd_deployments` already had the boundary — a typed
  config load, or a record list whose domain table renderer is pure — with presentation
  at the command top. The buffer/string renderers an earlier pass added there were churn
  and are reverted; the inventory records them as retained.
- Presentation types stay local: no generic command framework or accidental public API
  was added. Existing library outcomes remain the semantic source of truth.

### Every command module inventoried

| Module | Bounded/streaming verdict and disposition |
| --- | --- |
| cmd_assets | Bounded; `inspect` returns typed assets + checks + verdict, `run` prints and returns it |
| cmd_check | Bounded; `inspect` returns typed findings + verdict, `run` prints findings to stderr and the ok line to stdout |
| cmd_plan | Bounded and retained; typed config load, plan printed at the command top (no renderer) |
| cmd_alert | Mixed; dry-run bounded, send outcome matched and printed at the command boundary, sending progress stays before the request |
| cmd_target | Bounded target probes/report; existing target_report owns pure data/rendering |
| cmd_releases | Bounded and retained; record list and its domain table printed at the command top |
| cmd_deployments | Bounded and retained; record list and its domain table printed at the command top |
| cmd_open | Bounded link presentation plus optional browser-launch effect; existing URL resolution stays separate |
| cmd_fn | Bounded job mutation/identity output; existing manual-job result separates operation from simple presentation |
| cmd_secret | Bounded secret results; existing redacted_result renderer, stdin read remains an input effect |
| cmd_status | Mixed bounded probes/report and progress; existing status data/renderers retained, no global buffering |
| cmd_logs | Streaming follow/child forwarding, bounded Loki selection and fallback; preserve stream/error timing |
| cmd_local | Mixed infra lifecycle progress, bounded infra status and streaming local-run supervision; retain execution effects |
| cmd_migrate | Mixed status/dry-run results and connection/job progress/log forwarding; preserve lifecycle effects |
| cmd_rollback | Progress/mutations and restore reporting; keep announcements at their mutation phase |
| cmd_up | Streaming build/push/apply/rollout/exposure phases and dry-run; existing typed plan/outcomes retained |
| cmd_deploy | Mixed dry/emit/apply, migrations and rollout progress; existing typed plans/run outcomes retained |
| cmd_cloud_tf | Streaming Terraform child output and lifecycle progress; existing typed apply/destroy outcomes retained |
| cmd_cloud | Dispatch only; no independent presentation boundary |
| cmd_deploy_event | Internal Loki/reporting effects; not a bounded user command to buffer |
| cmd_destination | Input/context resolution only; no independent presentation boundary |
| main | Cmdliner/scaffold dispatch; no extra report abstraction |

- Validation: full CLI suite including real-command asset multi-failure, plan,
  check/target/alert exit checks and offline cloud lifecycle scenarios passes.
  A new real-command test captures untrimmed output files and checks exact stdout,
  stderr and exit status for check success and accepted/rejected alerts, plus that
  `sol assets` reaches its all-present footer on a clean checkout; its curl adapter
  never sends a network request.
- Demo/example: not applicable; no command behavior or app-author contract changes.
  No language-parity impact: this changes CLI presentation structure only.
