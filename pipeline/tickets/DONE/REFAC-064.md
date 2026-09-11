---
id: REFAC-064
type: audit-finding
severity: low
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-064/flatten-build-and-push
worktree: ../sun-REFAC-064-flatten-build-and-push
---

Flatten `local_builder.build_and_push` three-level Result nest with `let*`

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_cloud_deploy.ml:60–96` — the `local_builder` closure `build_and_push` contains three nested `match ... | Error msg -> ... | Ok () ->` sequences with a cleanup side-effect (`rm -rf ctx_dir`) duplicated in every error branch:

```ocaml
if rc <> 0 then Error "..."
else begin
  ...
  match run_streaming build_cmd log with
  | Error msg -> (cleanup ()); Error msg
  | Ok () ->
    match run_streaming push_cmd log with
    | Error msg -> (cleanup ()); Error msg
    | Ok () ->
      (cleanup ());
      Ok { image_tag = image_ref; digest }
end
```

`cleanup ()` appears three times; `Error msg` appears twice redundantly. Any additional step in the pipeline adds another level.

**Remediation:**

Use `Fun.protect` for cleanup and `let*` for the result chain:

```ocaml
let ( let* ) = Result.bind

let build_and_push ~workspace_path ~service_dir ~image_ref ~log =
  let ctx_dir = workspace_path ^ ".cloud-ctx" in
  let cleanup () = try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir))) with _ -> () in
  Fun.protect ~finally:cleanup (fun () ->
    let* () = copy_workspace workspace_path ctx_dir in
    let* () = run_streaming (build_cmd ctx_dir service_dir image_ref) log in
    let* () = run_streaming (push_cmd image_ref) log in
    let digest = get_digest image_ref in
    Ok { image_tag = image_ref; digest }
  )
```

Extract `copy_workspace`, `build_cmd`, `push_cmd` as small named helpers to keep the top-level pipeline readable.

## Review — automated checks passed
Build succeeds. Extracts copy_workspace, check_dockerfile, build_cmd, push_cmd helpers. Three duplicated cleanup calls replaced with Fun.protect ~finally:cleanup. Behavioral equivalence preserved. project/tickets/ unmodified in worktree.
