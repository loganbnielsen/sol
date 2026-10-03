open Cmdliner

let workspace_name = Sol_cli_workspace.current_name
let migrations_dir = "db/migrations"

open Result.Syntax

let ttl_s = Sol_cli_boundary_lease.default_ttl_s
let wait_s = Sol_cli_boundary_lease.rollback_wait_s

let apply_specs ~ensure_held ~ctx ~local ~release specs =
  let apply_spec (spec, applied_by) =
    let* () = ensure_held () in
    let* release_id_t =
      Sol_cli_release_id.of_string applied_by
      |> Result.map_error (fun message ->
        Printf.sprintf
          "release %s records an unreadable applied_by id: %s"
          release.Sol_cli_release.release_id
          message)
    in
    let spec = if local then Sol_cli_executor.local_development_spec spec else spec in
    let* () = Sol_cli_secret.verify_workload_secret ~ctx spec in
    let* yaml =
      Sol_cli_deployment_render.render_spec
        ~workspace:release.Sol_cli_release.workspace
        ?env:release.environment
        ~release_id:release_id_t
        ~secret_backend:Sol_cli_manifest.Kubernetes_live
        spec
    in
    let* () = Sol_cli_manifest.apply ~ctx yaml ~dry_run:false in
    Printf.printf
      "  applied %s/%s\n%!"
      (Sol_cli_deployment_plan.namespace_to_string spec.namespace)
      (Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name);
    Ok ()
  in
  specs |> Sol_cli_result.map_list apply_spec |> Result.map ignore
;;

let run_locked ~lease ~ctx ~local ~workspace ~facts release_id : (unit, string) result =
  let* release = Sol_cli_release_store.get ~ctx ~workspace ~release_id in
  Printf.printf "Rolling back %s to release %s\n%!" workspace release.release_id;
  let current_migrations =
    Sol_cli_workspace_model.migration_files facts
    |> List.map Sol_cli_plan_ids.Migration_file.to_string
  in
  let deps : Sol_cli_rollback.transaction_deps =
    { ensure_held = (fun () -> Sol_cli_boundary_lease.ensure_held lease)
    ; applied_migrations =
        (fun () ->
          Sol_cli_migration_gate.read_applied
            ~ctx
            ~workspace
            ~dir:migrations_dir
            ~table:(Sol_cli_migration.table_name ~workspace)
            ~services:(Sol_cli_workspace_model.services facts))
    ; apply =
        apply_specs
          ~ensure_held:(fun () -> Sol_cli_boundary_lease.ensure_held lease)
          ~ctx
          ~local
          ~release
    ; live_workloads =
        (fun () -> Sol_cli_rollback.live_workloads ~ctx ~workspace:release.workspace)
    ; prune = (fun ~live ~surplus -> Sol_cli_rollback.prune_workloads ~ctx ~live ~surplus)
    ; move_pointer = (fun () -> Sol_cli_release_store.move_pointer ~ctx release)
    ; verify_pointer = (fun () -> Sol_cli_rollback.verify_pointer ~ctx ~release)
    ; record_consumer_groups =
        (fun groups ->
          Sol_cli_deployment_state.record_consumer_groups ~ctx ~workspace groups)
    }
  in
  let* () = Sol_cli_rollback.execute ~release ~migrations_dir ~current_migrations ~deps in
  Printf.printf
    "Verified: workloads and pointer both name release %s.\n%!"
    release.release_id;
  Ok ()
;;

let resolve_commit ~ctx ~workspace ~target_string ~commit ~scope =
  let* events = Sol_cli_deployment_store.list ~ctx ~workspace in
  let resolution =
    Sol_cli_rollback.resolve_commit ~commit ?scope ~target:target_string events
  in
  match resolution with
  | Sol_cli_rollback.Commit_resolved release_id -> Ok release_id
  | Commit_invalid _ | Commit_no_match | Commit_ambiguous _ ->
    Error
      (Sol_cli_rollback.commit_resolution_to_string
         ~commit
         ~target:target_string
         ?scope
         resolution)
;;

let resolve_release_id ~ctx ~workspace ~target_string release_id commit scope
  : (string, string) result
  =
  match release_id, commit, scope with
  | Some id, None, None -> Ok id
  | None, None, None -> Error "pass a release id, or --commit <sha>."
  | _, None, Some _ ->
    Error
      "--scope only narrows --commit candidate resolution; pass --commit too, or a \
       release id directly."
  | Some _, Some _, _ -> Error "pass either a release id or --commit, not both."
  | None, Some commit, scope ->
    resolve_commit ~ctx ~workspace ~target_string ~commit ~scope
;;

let run ~ctx ?(local = false) ~target_string release_id commit scope =
  let workspace = workspace_name () in
  Sol_cli_exit.of_msg
    (let* facts = Sol_cli_workspace_model.load_cwd () in
     let* release_id =
       resolve_release_id ~ctx ~workspace ~target_string release_id commit scope
     in
     Sol_cli_boundary_lease.with_boundary_lease
       ~ctx
       ~workspace
       ~holder:Sol_cli_boundary_lease.Rollback
       ~ttl:ttl_s
       ~wait_s
       (fun lease -> run_locked ~lease ~ctx ~local ~workspace ~facts release_id))
;;

let release_id_arg =
  Arg.(
    value
    & pos 0 (some Sol_cli_args.text) None
    & info
        []
        ~docv:"RELEASE_ID"
        ~doc:
          "The release id to restore, e.g. r-1a2b3c4d5e6f7890. Omit when using --commit.")
;;

let commit_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "commit" ]
        ~docv:"SHA"
        ~doc:
          "Resolve to the release id a successful deploy of this commit produced on the \
           target, instead of naming a release id directly (FEAT-073). Lists candidates \
           and refuses to guess if more than one release matches.")
;;

let scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "With --commit, narrows which of that commit's releases to resolve -- the same \
           commit may have been deployed at more than one scope. Never means \"restore \
           part of a release\": a release's workload set is always restored whole.")
;;

let cmd =
  Cmd.v
    (Cmd.info
       "rollback"
       ~doc:
         "Restore a recorded release boundary. Refuses on a contracting migration since \
          that release, reconstructs and re-applies its workloads, moves the \
          current-release pointer, then verifies both independently.")
    Term.(
      const (fun release_id commit scope target ->
        let result =
          let* ctx = Cmd_destination.remote ~command:"rollback" target in
          run
            ~ctx
            ~target_string:(Option.value target ~default:"local")
            release_id
            commit
            scope
        in
        Sol_cli_exit.exit_on result)
      $ release_id_arg
      $ commit_arg
      $ scope_arg
      $ Cmd_destination.target_arg)
;;

let local_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Restore a recorded release boundary on the local cluster.")
    Term.(
      const (fun release_id commit scope ->
        Sol_cli_exit.exit_on
          (run
             ~ctx:Cmd_destination.local
             ~local:true
             ~target_string:"local"
             release_id
             commit
             scope))
      $ release_id_arg
      $ commit_arg
      $ scope_arg)
;;
