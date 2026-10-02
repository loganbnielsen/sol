---
id: CODE_LAYER-026
type: refactor
severity: medium
title: Give the filesystem boundary one read side, and one write_atomic
source: internal/pipeline/audits/2026-10-02_code_layer_audit.md
premise: "rg -q '^let read_file' cli/lib/base/sol_cli_fs.ml"
---

Give the filesystem boundary one read side, and one write_atomic

**Depends on:** None.

## Problem

`Sol_cli_fs` is the base layer's filesystem boundary, but it only has a write
side. Five production modules re-implement reading the same way, each with a
different contract for the same operation:

- `cli/lib/workspace/sol_cli_sol_yml.ml:161` — `try Ok (In_channel.with_open_bin … ) with Sys_error msg -> Error msg`
- `cli/lib/base/sol_cli_json.ml:10` — `read_file ~what path`, prefixed message, then JSON decode
- `cli/lib/base/sol_cli_migration_disposition.ml:46` — hand-rolled `open_in_bin`/`really_input_string`, `could not read <path>: <msg>`
- `cli/lib/base/sol_cli_scaffold_tree.ml:10` — `could not read <path>: <msg>`
- `cli/lib/cloud/sol_cli_supervised.ml:119` — `Some s` / `None`

One of them (`sol_cli_scaffold_tree`) uses `In_channel.with_open_text` (newline
translation) where the others read binary. `Sol_cli_json.read_file ~what` is
exported but has **no caller anywhere in the tree** — dead public surface. A
further 16 `In_channel.with_open_{bin,text} … input_all` reads in `cli/lib`
bypass the boundary and raise `Sys_error`. `sol_cli_supervised.write_atomic` is
a second `write_atomic` implementation (0o600, raising) beside
`Sol_cli_fs.write_atomic` (which already takes `?perm`);
`sol_cli_sol_yml.write_atomic` is a mode-preserving policy wrapper that already
delegates, so it is not a duplicate.

The defect is not the line count: it is that "read a file" has no single
meaning in this codebase, so each new caller has to decide again whether a
missing file is an `Error`, a `None`, or an exception, and whether newlines are
translated.

## Remediation

1. Add `read_file : string -> (string, string) result` and
   `read_file_opt : string -> string option` to `Sol_cli_fs`, implemented once
   over `In_channel.with_open_bin`, and export them from `sol_cli_fs.mli`.
2. Route the five readers through it, keeping each module's own error wording
   by mapping the message at the call site where the wording is the module's
   (do not re-read the file to change a message).
3. Remove the dead `Sol_cli_json.read_file` from `sol_cli_json.ml` and its
   `.mli` (it has no caller), and have `sol_cli_supervised.write_atomic`
   delegate to `Sol_cli_fs.write_atomic ~perm:0o600`, preserving its
   raise-on-failure behaviour by mapping the `Error`. Leave
   `sol_cli_sol_yml.write_atomic` as the mode-preserving policy wrapper it
   already is.
4. Migrate the remaining inline `input_all` reads in `cli/lib` to the shared
   helper where a `Result` is already the caller's shape too; do not change
   readers whose module genuinely needs to raise.
5. Leave `cli/lib/base/sol_cli_sensitive_vars.ml` and any secret/identity path
   alone — that file is owned by the secrets workstream.

## Acceptance criteria

- `rg -n '^let read_file' cli/lib` returns no module-local definition except
  the shared one in `sol_cli_fs.ml`; `rg -n 'val read_file' cli/lib/base/sol_cli_fs.mli`
  returns the shared surface.
- A missing file and a permission failure both yield `Error` carrying the path;
  a readable file yields its exact bytes (no newline translation).
- `cli/test/inline/test_sol_yml.ml`, `test_json.ml`, `test_migration_disposition.ml`,
  `test_scaffold.ml`, and the supervised-operation tests still pass, and a
  focused test in `cli/test/inline/test_fs.ml` covers the shared read.
- Update a runnable example/demo for application-facing behavior, or record why
  this is an internal-only refactor.
- Record the per-language capability verdict for framework/application
  contracts, or explain why language parity is unaffected.

## Completion (2026-10-02)

- **Premise re-verified** at `origin/main` `8cb09659`: `sol_cli_fs.mli` exposed no read, five modules each defined `read_file`, and `Sol_cli_json.read_file ~what` had no caller. Correction made in this pass: the audit and this ticket first said `write_atomic` was "defined three times" — `sol_cli_sol_yml.write_atomic` is a mode-preserving wrapper that already delegates, so only `sol_cli_supervised` was a second implementation. Both documents were corrected before implementation.
- **Fix.** Added `Sol_cli_fs.read_file` (`In_channel.with_open_bin`, `(string, string) result`) and `Sol_cli_fs.read_file_opt`, exported from `sol_cli_fs.mli`. Routed `sol_cli_sol_yml` (local deleted), `sol_cli_scaffold_tree` (local deleted, `could not read <path>: <msg>` wording kept), `sol_cli_migration_disposition` (delegates, wording kept) and `sol_cli_supervised` (`read_file = Sol_cli_fs.read_file_opt`). Deleted the dead `Sol_cli_json.read_file` from the `.ml` and `.mli`. `cli/lib/base/sol_cli_sensitive_vars.ml` was not touched (secrets workstream).
- **Write side, deliberately not consolidated.** `sol_cli_supervised.write_atomic` was first made to delegate to `Sol_cli_fs.write_atomic ~perm:0o600`, but it raises on failure today and the shared helper returns a `Result`; the delegation needed an explicit `failwith`, which `check_no_exception_control_flow.sh` (REFAC-133) refuses, and returning the `Error` instead would change how a lifecycle path reports a failed state write. The duplicate was therefore left in place, exactly as before. Consolidating it needs the supervisor's write failures to be returned and handled, which is REFAC-133's concern, not this ticket's. `sol_cli_sol_yml.write_atomic` is a mode-preserving wrapper and was left alone.
- **Tests.** New `cli/test/inline/test_fs.ml` case (exact bytes with no newline translation, an `Error` naming the missing path, `read_file_opt` returning `None`). The full `cli/test/inline` suite passes.
- **Guards.** `check_single_runner.sh`, `check_no_exception_control_flow.sh` and their mutation suites pass; `check_no_comments.sh` clean.
- Validation: full `dune build`; `dune fmt` clean.
- **Demo/example: not applicable** — internal CLI filesystem plumbing, no app-author surface. **Language parity: no impact** — no framework or application contract change.
