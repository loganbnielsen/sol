---
id: AUDIT-086
type: audit-finding
severity: low
title: An unreadable existing workflow file bypasses sol ci --force protection
source: internal/pipeline/audits/2026-10-02_error_collapse_audit.md
---

An unreadable existing workflow file bypasses sol ci --force protection

**Depends on:** None.

## Problem

`init_github` in `cli/lib/workspace/sol_cli_ci.ml` reads the target workflow with
`Sol_cli_fs.read_file_opt`:

```ocaml
match Sol_cli_fs.read_file_opt path with
| Some existing when String.equal existing rendered -> Ok { written = false; path }
| Some _ when not force -> Error "… already exists and differs … re-run with --force …"
| _ -> … write_atomic path rendered; Ok { written = true; path }
```

`read_file_opt` returns `None` for every read error, so an existing file that
cannot be read (permission, I/O error) falls into the `| _ ->` arm and is
overwritten **without `--force`**.

## Impact

The `--force` guard exists to stop Sol silently clobbering a hand-edited
workflow. An unreadable file — exactly the case where the guard should be most
conservative — instead disables it and overwrites the file. This is the
`unobservable → absent` collapse permitting an unsafe write.

## Remediation

Use `Sol_cli_fs.read_file`, distinguish `Error` (report it and refuse) from the
genuinely-absent case (`Sys.file_exists path = false`, which is the only case
that should write a new file). Keep `--force` as the explicit override for a
file that was read and differs.

## Acceptance criteria

- An unreadable existing workflow refuses with the read error, even without
  `--force`, and is not overwritten.
- An absent file is still written; an identical file is still a no-op; a
  readable differing file still requires `--force`.

**Demo/example coverage:** Not applicable — CLI scaffold support file; no
app-author surface.

**TypeScript-parity note (DEC-022):** No language-parity impact — workspace CI
scaffolding in the OCaml CLI.
