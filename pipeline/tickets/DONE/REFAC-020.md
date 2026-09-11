---
id: REFAC-020
type: refactor
severity: medium
branch: REFAC-020/unify-git-sha
worktree: /home/lbendtly/Code/sun-REFAC-020-unify-git-sha
source: codebase simplification review 2026-06-15
---

Unify three divergent `git_sha()` implementations in CLI commands

**Depends on:** None.

**Description:**

Three CLI commands each define their own `git_sha()` with subtly different implementations:

| File | Lines | Method |
|------|-------|--------|
| `cli/sun/bin/cmd_up.ml` | 258–260 | `Sun_cli_shell.run_cmd_to_string` — no temp file, reads stdout inline |
| `cli/sun/bin/cmd_deploy.ml` | 10–17 | Writes to temp file via `Sys.command`, reads back, cleans up manually |
| `cli/sun/bin/cmd_cloud.ml` | 512–519 | Same temp-file pattern as `cmd_deploy.ml` |

The temp-file variants are also vulnerable to the uncleaned-temp-file bug: if the git command fails, the temp file leaks. `cmd_up.ml`'s approach is correct.

**Remediation:**

1. Add to `cli/sun/lib/sun_cli_shell.ml`:
   ```ocaml
   (* Returns the short HEAD SHA, or "dev" if git is unavailable or not in a repo. *)
   let git_sha () =
     let s = run_cmd_to_string "git rev-parse --short HEAD 2>/dev/null" in
     let s = String.trim s in
     if s = "" then "dev" else s
   ```
2. Delete the three local `git_sha` definitions in `cmd_up.ml`, `cmd_deploy.ml`, `cmd_cloud.ml`.
3. Replace each call site with `Sun_cli_shell.git_sha ()`.

**Acceptance criteria:**

- `grep -rn "let git_sha\|rev-parse.*short" cli/sun/bin/` returns zero hits.
- `dune build` passes.
- `sun up`, `sun deploy`, and `sun cloud` still embed the correct SHA into image tags and YAML.

## Review — automated checks passed
git_sha() centralised in Sun_cli_shell; three bin definitions removed; build clean; no rev-parse in bin/
