---
id: INFRA-001
branch: INFRA-001/pipeline-gc
worktree: /home/lbendtly/Code/sun-INFRA-001-pipeline-gc
type: feature
severity: medium
source: manual review 2026-06-15
---

Add `sundev pipeline gc` to remove worktrees for merged tickets, and call it automatically from `pipeline merge`

**Depends on:** None.

**Background:**

`sundev pipeline merge` already calls `git worktree remove <path> --force` on the success path (lines 403–407 and 438–442 of `cmd_pipeline.ml`). But three situations leave orphaned worktrees behind:

1. **Merge reverted by test failure** — the `BLOCKED_BY_PERFORMANCE` branch (lines 413–430) moves the ticket but never removes the worktree. This is intentional for active investigation, but once the ticket is re-resolved and merged, no cleanup runs.
2. **Manual `git merge`** — engineers occasionally merge branches outside the pipeline. The post-merge hook only shows a perf table; it does not clean up worktrees.
3. **Previous pipeline runs that failed mid-cleanup** — if `run_tests.sh` raised or the process was killed after the merge commit but before `git worktree remove`, the worktree is left registered and on disk.

Currently 15 worktrees are sitting in `~/Code/sun-*`, several belonging to tickets already in `DONE/`.

---

**Remediation:**

### 1. Add `run_gc` and a `gc` subcommand to `cmd_pipeline.ml`

```ocaml
let run_gc dry_run =
  (* Parse all registered worktrees from git worktree list --porcelain.
     Each worktree stanza looks like:
       worktree /home/.../sun-AUDIT-062-auth-before-body-read
       HEAD <sha>
       branch refs/heads/AUDIT-062/auth-before-body-read       *)
  let lines = Sundev_shell.run_cmd_lines "git worktree list --porcelain" in
  (* collect (path, branch) pairs, skip the main worktree (first stanza, no ticket branch) *)
  let worktrees = ... in
  List.iter (fun (wt_path, branch) ->
    (* Extract ticket ID from branch: "AUDIT-062/auth-before-body-read" → "AUDIT-062" *)
    let ticket_id = match String.index_opt branch '/' with
      | Some i -> String.sub branch 0 i
      | None   -> branch
    in
    let done_path = Printf.sprintf "project/tickets/DONE/%s.md" ticket_id in
    if Sys.file_exists done_path then begin
      Printf.printf "gc: %s  (ticket %s is DONE)\n%!" wt_path ticket_id;
      if not dry_run then begin
        ignore (Sundev_shell.run_cmd
          (Printf.sprintf "git worktree remove %s --force" (Filename.quote wt_path)));
        ignore (Sundev_shell.run_cmd ~echo:false
          (Printf.sprintf "git branch -d %s 2>/dev/null; true" (Filename.quote branch)))
      end
    end
  ) worktrees
```

Expose as `sundev pipeline gc [--dry-run]`.

### 2. Call `run_gc` at the end of `run_merge`

After the per-ticket loop in `run_merge` completes, call `run_gc ~dry_run` unconditionally. This catches any worktrees that were missed in a prior partial run, without requiring a separate command invocation.

### 3. Add a `post-merge` git hook

Create `tools/hooks/post-merge` (alongside the existing `pre-commit` and `post-commit`):

```bash
#!/usr/bin/env bash
[ "${SUN_SKIP_HOOKS:-0}" = "1" ] && exit 0
REPO_ROOT="$(git rev-parse --show-toplevel)"
SUNDEV="$REPO_ROOT/_build/default/tools/sundev/bin/main.exe"
[ -x "$SUNDEV" ] || exit 0
"$SUNDEV" pipeline gc
```

Install via `platform/local/scripts/install-hooks.sh` alongside the existing hooks.

---

**Acceptance criteria:**

- `sundev pipeline gc` removes worktrees and branches for all tickets currently in `DONE/`, and prints one line per worktree removed.
- `sundev pipeline gc --dry-run` prints what it would remove without touching anything.
- Running `sundev pipeline gc` when no orphaned worktrees exist exits cleanly with no output.
- `sundev pipeline merge` calls `gc` automatically at the end of each run.
- The `post-merge` hook runs `gc` after a manual `git merge` (verify: merge a branch manually, confirm the worktree disappears).
- The 15 existing orphaned worktrees in `~/Code/sun-*` are cleaned up by the first `gc` run.
- `dune build` passes.

## Review — automated checks passed
run_gc added with Filename.quote safety, gc_cmd registered in pipeline group, run_merge calls run_gc at tail, post-merge hook is executable and SUN_SKIP_HOOKS-guarded, dune build clean, project/tickets/ untouched
