---
id: REFAC-039
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
branch: REFAC-039/use-string-starts-with
worktree: /home/lbendtly/Code/sun-REFAC-039-use-string-starts-with
---

Replace two hand-rolled string utilities with stdlib equivalents (OCaml 5.4)

**Depends on:** REFAC-034.

**Description:**

Two string helper functions in the CLI lib are hand-rolled replacements for functions available in OCaml 5's standard library:

**1. `starts_with ~prefix s` in `sun_cli_release_inspection.ml:130–133`:**
```ocaml
let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix
```
OCaml 4.13+ (this project uses 5.4.1) ships `String.starts_with ~prefix s` with identical semantics. This function is used at lines 153, 161, and in `field_after_prefix`.

**2. `normalize` in `sun_cli_scaffold.ml:36–37`:**
```ocaml
let normalize s =
  String.map (function '-' -> '_' | c -> c) (String.lowercase_ascii s)
```
This is fine as-is — there's no stdlib equivalent. But it's worth noting it as a non-issue so reviewers don't flag it.

After REFAC-034 lands, the two `contains`/`contains_string` variants will also be gone. The remaining string utility gap is `starts_with`.

**Remediation:**

1. Delete `starts_with` from `sun_cli_release_inspection.ml`.
2. Replace all three call sites with `String.starts_with ~prefix`.
3. Confirm no other local `starts_with` definitions exist: `grep -rn "let starts_with" cli/`.

**Acceptance criteria:**

- `grep -rn "let starts_with" cli/` returns zero hits.
- `dune build` passes.
- `sun deploy` and `sun cloud deploy` manifest parsing is unchanged (these are the callers of `split_manifest_docs` / `field_after_prefix`).
