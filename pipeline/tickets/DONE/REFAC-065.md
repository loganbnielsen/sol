---
id: REFAC-065
type: audit-finding
severity: low
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-065/option-filter
worktree: ../sun-REFAC-065-option-filter
---

Replace `Option.bind (...) (fun s -> if s = "" then None else Some s)` with `Option.filter`

**Depends on:** None.

**Description:**

`cli/sun/lib/sun_cli_scaffold_templates.ml` contains at least two instances of the same verbose idiom (lines 554 and 653):

```ocaml
let postgres_url = Option.bind (Sys.getenv_opt "POSTGRES_URL") (fun s -> if s = "" then None else Some s) in
```

This reads an environment variable and discards the result if it is empty. `Option.filter` expresses this directly:

```ocaml
let postgres_url = Sys.getenv_opt "POSTGRES_URL" |> Option.filter (fun s -> s <> "") in
```

The current form requires the reader to trace through `Option.bind`, a lambda, a conditional, and two `Some`/`None` branches to understand a simple "empty string means absent" rule.

**Remediation:**

Replace both occurrences with the `Option.filter` form. Search the codebase for any other sites using the same `Option.bind (f ()) (fun s -> if s = "" then None else Some s)` pattern and apply the same fix.

`Option.filter` is available since OCaml 4.08.

## Review — automated checks passed
Build clean. Both Option.bind empty-string guards replaced with Option.filter. No ticket files modified.
