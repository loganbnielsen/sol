---
id: REFAC-034
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
branch: REFAC-034/consolidate-string-contains
worktree: /home/lbendtly/Code/sun-REFAC-034-consolidate-string-contains
---

Consolidate two substring-search implementations with conflicting argument conventions

**Depends on:** None.

**Description:**

Two substring-search functions exist with opposite argument order and different naming:

```ocaml
(* cli/sun/bin/cmd_up.ml:21–29 — positional args, haystack first *)
let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec go i = i <= hl - nl
      && (String.sub haystack i nl = needle || go (i + 1))
    in
    go 0

(* cli/sun/lib/sun_cli_workspace.ml:8–16 — labeled args, needle first *)
let contains_string ~needle s =
  let nl = String.length needle in
  let sl = String.length s in
  let found = ref false in
  for i = 0 to sl - nl do
    if not !found && String.sub s i nl = needle then found := true
  done;
  !found
```

The argument reversal (`haystack needle` vs `~needle s`) means neither can be used as a drop-in replacement for the other. The workspace version uses a mutable flag; the cmd_up version uses recursion. Both are O(n×m).

**Remediation:**

1. Add a single canonical version to `cli/sun/lib/sun_cli_shell.ml`:
   ```ocaml
   let string_contains ~needle haystack =
     let nl = String.length needle and hl = String.length haystack in
     if nl = 0 then true
     else if nl > hl then false
     else
       let rec go i = i <= hl - nl
         && (String.sub haystack i nl = needle || go (i + 1))
       in
       go 0
   ```
   (Labeled `~needle` for clarity at call sites; `haystack` as the main positional arg.)

2. Delete `contains` from `cmd_up.ml` and update its call sites to `Sun_cli_shell.string_contains ~needle:...`.

3. Delete `contains_string` from `sun_cli_workspace.ml` and update its call sites to `Sun_cli_Shell.string_contains ~needle:...`.

**Acceptance criteria:**

- `grep -rn "let contains\b\|let contains_string\b" cli/` returns zero hits.
- `dune build` passes.
- `sun up` port-forward detection and workspace string matching behave identically.

## Review — automated checks passed
string_contains ~needle centralised in Sun_cli_shell; contains removed from sun_cli_port_forward.ml and contains_string from sun_cli_workspace.ml; build clean; zero let contains hits in cli/ (excluding test)
