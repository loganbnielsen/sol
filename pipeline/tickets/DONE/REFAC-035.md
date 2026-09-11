---
id: REFAC-035
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
branch: REFAC-035/extract-scan-dir
worktree: /home/lbendtly/Code/sun-REFAC-035-extract-scan-dir
---

Extract shared `scan_dir` skeleton from three near-identical discovery functions in deployment_plan

**Depends on:** None.

**Description:**

`cli/sun/lib/sun_cli_deployment_plan.ml` contains three functions that all implement the same directory-scan scaffold — `readdir`, skip hidden entries, accumulate into a `ref []`, guard against missing dir — then do different things inside the loop body:

| Function | Lines | Scans | Yields |
|----------|-------|-------|--------|
| `discover_schema_subjects` | 176–213 | `events/` (2 levels) | `domain.Event` strings |
| `discover_topics` | 218–259 | `events/` (2 levels, reads file contents) | topic name strings |
| `discover_migrations` | 261–272 | `db/migrations/` (1 level) | `.sql` filenames |

The outer skeleton — `if not (Sys.file_exists dir && Sys.is_directory dir) then [] else begin let acc = ref [] in (try Array.iter ... (Sys.readdir dir) with _ -> ()); List.sort_uniq ... !acc end` — is repeated with copy-paste variations across all three.

**Remediation:**

Add a helper at the top of `sun_cli_deployment_plan.ml` (private to the module):

```ocaml
(* Fold over entries in [dir], silently returning [] if the dir is absent. *)
let fold_dir dir ~init ~f =
  if not (Sys.file_exists dir && Sys.is_directory dir) then init
  else begin
    let acc = ref init in
    (try Array.iter (fun entry ->
       let path = Filename.concat dir entry in
       acc := f !acc entry path
     ) (Sys.readdir dir)
    with _ -> ());
    !acc
  end
```

Rewrite `discover_migrations` with `fold_dir` first (it's the simplest). Then refactor the two `events/` scanners similarly. Each becomes a short loop body using `fold_dir`.

**Acceptance criteria:**

- The three `discover_*` functions no longer contain inline `ref []` + `Array.iter (Sys.readdir ...)` loops.
- `dune build` passes.
- `sun up` produces identical plan output (topics, migrations, schema subjects unchanged).

## Review — automated checks passed
fold_dir helper added; three discover_* functions refactored to use it; no inline ref[]+Array.iter(Sys.readdir) loops remain; all deployment_plan tests pass
