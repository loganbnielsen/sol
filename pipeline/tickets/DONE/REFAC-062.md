---
id: REFAC-062
type: audit-finding
severity: medium
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-062/flatten-pg-functions
worktree: ../sun-REFAC-062-flatten-pg-functions
---

Flatten `pg_create_project`, `pg_create_release`, and `pg_list_releases` pyramids with `let*`

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_cloud_registry.ml` (inside `Pg_registry`) contains three heavily nested functions:

**`pg_create_project` (lines 147–158):** Three levels of nested `match` on `Result`/`Option`. The happy path (insert new project) is indented three levels in.

**`pg_create_release` (lines 160–214):** Four-plus levels of nesting. The transaction body alone has three levels of `match` on `Db.exec` results. A `List.fold_left` accumulates errors while iterating over service names and log lines — a pattern that reads differently from the surrounding code style.

**`pg_list_releases` (lines 216–233):** Three levels. The per-row service fetch is done inside a `List.map` that returns `result list`, then another match inspects that list for the first error — a pattern that could be replaced with `List.fold_left` returning `result` or a `traverse`-style helper.

**Remediation:**

Introduce `let ( let* ) = Result.bind` at the top of the `Pg_registry` module and rewrite all three functions using monadic binding:

```ocaml
let pg_create_project pool ~workspace =
  let project_id = Sun_cli_registry.project_id_of_workspace workspace in
  let* existing = Db.find pool find_project_by_workspace_q workspace
    |> Result.map_error storage_err_to_string in
  match existing with
  | Some row -> Ok (row_to_project row)
  | None ->
    let* () = Db.exec pool upsert_project_q (project_id, workspace)
      |> Result.map_error storage_err_to_string in
    let* row = Db.find pool find_project_q project_id
      |> Result.map_error storage_err_to_string in
    match row with
    | None -> Error "project not found after insert"
    | Some row -> Ok (row_to_project row)
```

For `pg_create_release`, extract the service-insert and log-append loops into named helpers so the top-level function reads as a sequential pipeline.

For `pg_list_releases`, use `List.fold_left (fun acc row -> let* acc = acc in ...) (Ok []) rows` to fail-fast on the first service-fetch error.

## Review — automated checks passed
Build clean. Introduces let* = Result.bind and db error-mapping helper, flattens pg_create_project/pg_create_release/pg_list_releases, extracts insert_services and append_log_lines helpers. No ticket files modified.
