---
id: FRIC-004
type: dogfood-finding
severity: blocker
source: project/dogfood/RUN_2026-06-12b.md
branch: FRIC-004/option-filter-fix
worktree: ../sun-FRIC-004-option-filter-fix
---

**Depends on:** None.

Generated workspace fails `dune build` — `Option.filter` is not in OCaml stdlib

**Description:** The DOGFOOD-010 fix added `Option.filter (fun s -> s <> "") (Sys.getenv_opt "POSTGRES_URL")` to the generated service/worker `main.ml` templates in `cli/sun/lib/sun_cli_cmd_new.ml`. `Option.filter` does not exist in the OCaml 5.4.1 standard library. Every freshly generated workspace immediately fails `dune build` with `Unbound value Option.filter`.

**Impact:** A first-time user following the quickstart runs `sun new workspace myapp && dune build` and gets a compile error on a file they didn't write, with no hint about how to fix it. The two-minute claim is broken at step 2.

**Remediation:** In `cli/sun/lib/sun_cli_cmd_new.ml`, replace all occurrences of:
```ocaml
Option.filter (fun s -> s <> "") (Sys.getenv_opt "POSTGRES_URL")
```
with:
```ocaml
Option.bind (Sys.getenv_opt "POSTGRES_URL") (fun s -> if s = "" then None else Some s)
```
This is the correct OCaml idiom for filtering an option value. Apply to both the `svc` and `worker` entrypoint templates. Then regenerate a workspace and verify `dune build` succeeds.

## Review — automated checks passed
FRIC-004 remediation is scoped correctly, builds, and generated service/worker templates no longer use Option.filter.
