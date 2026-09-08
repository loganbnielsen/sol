---
id: REFAC-030
type: refactor
severity: high
branch: REFAC-030/unified-app-scanner
worktree: /home/lbendtly/Code/sun-REFAC-030-unified-app-scanner
source: codebase simplification review 2026-06-15
---

Replace three hand-rolled `app/` scanners in bin files with `Sun_cli_manifest.discover_services`

**Depends on:** None.

**Description:**

`Sun_cli_manifest.discover_services` already does a full structured scan of `app/` — it returns typed `service` records, handles hidden files, and exits gracefully with a clear error when `app/` is missing. Despite this, three bin-level commands each reimplemented a simpler, ad-hoc version:

| File | Function | Lines | What it misses vs. manifest version |
|------|----------|-------|--------------------------------------|
| `cli/sun/bin/cmd_status.ml` | `discover_domains` | 8–21 | Returns strings not typed records; no "not found" error |
| `cli/sun/bin/cmd_secret.ml` | `discover_namespaces` | 5–20 | Also maps through `namespace_of` — already available in deployment_plan |
| `cli/sun/bin/cmd_logs.ml` | `find_service_by_name` | 7–29 | Separate two-level scan; misses Dockerfile filter from manifest version |

If the `app/` layout convention ever changes, all three need updating independently.

**Remediation:**

1. **`cmd_status.ml`**: Replace `discover_domains ()` with `List.sort_uniq String.compare (List.map (fun s -> s.Sun_cli_manifest.domain) (Sun_cli_manifest.discover_services ~filter_path:None))`.

2. **`cmd_secret.ml`**: Replace `discover_namespaces ()` with `discover_services ~filter_path:None` + `Sun_cli_deployment_plan.namespace_of` mapping. The current function already calls `namespace_of` — wire it off the manifest list instead.

3. **`cmd_logs.ml`**: Replace `find_service_by_name name` with `List.filter (fun s -> s.Sun_cli_manifest.name = name || Filename.basename s.dir = name) (Sun_cli_manifest.discover_services ~filter_path:None)`.

Delete the three local discovery functions.

**Acceptance criteria:**

- `grep -rn "let discover_domains\|let discover_namespaces\|let find_service_by_name" cli/sun/bin/` returns zero hits.
- `sun status`, `sun secret list`, and `sun logs <service>` produce the same output as before.
- `dune build` passes.

## Review — automated checks passed
All acceptance criteria met: no banned scanner functions, build clean, diff scoped to three cmd files only
