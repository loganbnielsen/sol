---
id: REFAC-033
type: refactor
severity: low
branch: REFAC-033/remove-dup-read-file
worktree: /home/lbendtly/Code/sun-REFAC-033-remove-dup-read-file
source: codebase simplification review 2026-06-15
---

Remove duplicate `read_file` from `sun_cli_workspace.ml` — `sun_cli_shell.ml` already has it

**Depends on:** None.

**Description:**

`read_file` is implemented twice in the CLI lib:

```ocaml
(* sun_cli_shell.ml:1–4 *)
let read_file path =
  let ic = open_in path in
  let s = In_channel.input_all ic in
  close_in ic; s

(* sun_cli_workspace.ml:18–23 *)
let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s
```

Both read the entire file into a string and close the channel. The workspace version uses `in_channel_length + really_input_string`, which can misbehave on non-seekable file descriptors (pipes, `/proc` files) but is otherwise equivalent for regular files. `In_channel.input_all` is safer and idiomatic for OCaml 5.

Neither version handles exceptions (channel stays open on error). Neither is the concern here — they're identical in purpose.

**Remediation:**

1. Delete `read_file` from `sun_cli_workspace.ml`.
2. Update every internal caller in `sun_cli_workspace.ml` to use `Sun_cli_shell.read_file` (or open Sun_cli_shell at the top of the file).
3. Confirm no external callers were using `Sun_cli_workspace.read_file` directly (check with `grep -rn "Sun_cli_workspace.read_file" cli/`).

**Acceptance criteria:**

- `grep -rn "let read_file" cli/sun/lib/` returns exactly one hit (in `sun_cli_shell.ml`).
- `dune build` passes.

## Review — automated checks passed
Exactly one read_file remains in sun_cli_shell.ml, workspace.ml caller updated, build passes
