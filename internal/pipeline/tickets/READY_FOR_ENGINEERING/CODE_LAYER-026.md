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

Two use `In_channel.with_open_text` (newline translation) where the others use
`with_open_bin`. A further 16 `In_channel.with_open_{bin,text} … input_all`
reads in `cli/lib` bypass the boundary and raise `Sys_error`. `write_atomic` is
likewise defined three times — `cli/lib/base/sol_cli_fs.ml:85`,
`cli/lib/workspace/sol_cli_sol_yml.ml:166` (mode-preserving), and
`cli/lib/cloud/sol_cli_supervised.ml:125` (0o600) — although
`Sol_cli_fs.write_atomic` already takes `?perm`.

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
3. Have `sol_cli_sol_yml.write_atomic` and `sol_cli_supervised.write_atomic`
   delegate to `Sol_cli_fs.write_atomic ?perm`.
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
