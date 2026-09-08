---
id: REFAC-019
type: refactor
severity: medium
branch: REFAC-019/centralise-workspace-name
worktree: /home/lbendtly/Code/sun-REFAC-019-centralise-workspace-name
source: codebase simplification review 2026-06-15
---

Centralise `workspace_name()` — currently defined 7 times across CLI commands

**Depends on:** None.

**Description:**

`let workspace_name () = Filename.basename (Sys.getcwd ())` is copy-pasted into seven places:

| File | Line(s) |
|------|---------|
| `cli/sun/bin/cmd_up.ml` | 256 |
| `cli/sun/bin/cmd_deploy.ml` | 8 |
| `cli/sun/bin/cmd_logs.ml` | 3 |
| `cli/sun/bin/cmd_status.ml` | 6 |
| `cli/sun/bin/cmd_secret.ml` | 3 |
| `cli/sun/bin/cmd_rollback.ml` | 6 |
| `cli/sun/bin/cmd_migrate.ml` | 8 (inlined as `cwd_name`) |
| `cli/sun/bin/cmd_cloud.ml` | 613, 745, 809 (inlined inline) |

Every copy is identical. There is already a natural shared home: `cli/sun/lib/sun_cli_shell.ml`.

**Remediation:**

1. Add to `cli/sun/lib/sun_cli_shell.ml`:
   ```ocaml
   let workspace_name () = Filename.basename (Sys.getcwd ())
   ```
2. Delete every local `workspace_name` definition across the eight files above.
3. Replace all inline `Filename.basename (Sys.getcwd ())` expressions in `cmd_cloud.ml` and `cmd_migrate.ml` with `Sun_cli_shell.workspace_name ()`.

**Acceptance criteria:**

- `grep -rn "workspace_name\|Filename.basename.*getcwd" cli/sun/bin/` returns zero hits.
- `dune build` passes.
- `sun up`, `sun deploy`, `sun logs`, `sun status`, `sun secret`, `sun rollback` all still resolve the workspace name correctly.

## Review — automated checks passed
workspace_name() centralised in Sun_cli_shell; eight local definitions removed from bin files; build clean; zero let workspace_name hits in bin/
