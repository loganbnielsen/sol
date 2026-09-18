---
id: FRIC-022
type: dogfood-finding
severity: medium
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Workspace name is silently normalized, and differently per surface

**Description:** `sol new workspace dogfood-2026-09-13` created a directory named `dogfood_2026_09_13/` (hyphens → underscores; `Sol_cli_scaffold.normalize`, `cli/sol/lib/sol_cli_scaffold.ml:92-97`) and the generated SQL table is `dogfood_2026_09_13_notifications`. The Kubernetes namespaces are `dogfood-2026-09-13-payments` / `-comms` (underscores → hyphens; `Sol_cli_kubernetes_name.normalize`, `cli/sol/lib/sol_cli_kubernetes_name.ml:4`). Both are deliberate for their target grammars, but the scaffold prints no warning and the two forms differ.

**Impact:** `cd dogfood-2026-09-13` (the name the user typed, and the name the dogfood skill suggests) fails. The user must infer a naming mapping that is nowhere stated; shell history and scripts keyed to the typed name break. This doubles as a mild correctness trap for anyone joining the three identifiers (dir ↔ SQL table ↔ namespace).

**Remediation:** At scaffold time, print the normalized workspace name explicitly (e.g. "created `dogfood_2026_09_13` — hyphens are not valid in an OCaml module name"), and document the mapping (dir/OCaml `_`, Kubernetes `-`) in the generated README. Alternatively accept one canonical input form and reject the other with a clear message.

Related: FRIC-015 (the scaffold's next-steps text is the natural place to state the final directory name).

## Completion notes

- `sol new workspace` now prints an explicit note when the input name is not already a valid OCaml/SQL identifier, showing the raw name, the normalized directory/SQL name, and the hyphenated Kubernetes form (e.g. `fric022-check` → directory `fric022_check`, namespace `fric022-check-payments`).
- The generated workspace README's "Project layout" section now documents the `_` (directory/OCaml/SQL) vs `-` (Kubernetes) mapping.
- Verified with both hyphenated and plain inputs; full `dune build` clean and `test_workspace` (6 tests) passes.
