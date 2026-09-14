(* sol rollback — restore a recorded release boundary (FEAT-066, DEC-018).

   Boring orchestration on top of already-proven pieces: resolve the release
   record, refuse a controller-owned release, refuse on a contracting migration
   since that release, reconstruct and re-render its own workloads, apply them,
   verify the live workload set, and only then move the current-release pointer
   and verify it. Never `kubectl rollout undo`, which cannot restore config,
   volumes or ingress -- restoration comes from the release record.

   A refused rollback (GitOps-owned, migration boundary, a corrupt/missing
   record) leaves the cluster untouched: every check before "apply" only reads.
   The pointer moves only after the live workload set agrees with the restored
   release, so a verification failure never leaves the pointer claiming a
   transition that did not happen. *)

open Cmdliner

let workspace_name () = Filename.basename (Sys.getcwd ())
let migrations_dir = "db/migrations"
let ( let* ) = Result.bind

(* FEAT-072: the mutation lease. Rollback first establishes quiescence: it
   acquires the workspace's boundary lease, aborting and waiting out an in-flight
   deploy rather than racing it (DEC-018: "abort, establish quiescence, then
   restore"). The restoration runs under the lease, which the bracket releases
   however this returns.

   The sequence below returns a result rather than calling [exit]: only the
   command edge turns a refusal into a process exit, so the lease is released by
   [Fun.protect] on every path and no [at_exit] is needed. The ordering itself
   is [Sol_cli_rollback.execute] (FEAT-075) -- this module only wires the
   concrete deps and turns the result into process exit / stdout. *)
let ttl_s = Sol_cli_boundary_lease.default_ttl_s
let wait_s = Sol_cli_boundary_lease.rollback_wait_s

(* render + apply. Kubernetes_live: a real apply to a live cluster reads secret
   values from this process's environment, exactly as sol up/sol deploy do for
   a direct (non-GitOps) apply -- the release record only ever carries secret
   key names, never values. GitOps-mode rollback (content and pointer
   travelling in one emitted commit) is not this pass's concern. *)
let apply_specs ~ctx ~release ~release_id_t specs =
  try
    List.iter
      (fun (spec : Sol_cli_deployment_plan.service_spec) ->
         match
           Sol_cli_deployment_render.render_spec
             ~workspace:release.Sol_cli_release.workspace
             ?env:release.Sol_cli_release.environment
             ~release_id:release_id_t
             ~secret_backend:Sol_cli_manifest.Kubernetes_live
             spec
         with
         | Error msg -> raise (Sol_cli_manifest.Deploy_failed msg)
         | Ok yaml ->
           Sol_cli_manifest.apply ~ctx yaml ~dry_run:false;
           Printf.printf
             "  applied %s/%s\n%!"
             (Sol_cli_deployment_plan.namespace_to_string spec.namespace)
             (Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name))
      specs;
    Ok ()
  with
  | Sol_cli_manifest.Deploy_failed msg -> Error msg
;;

let run_locked ~ctx ~workspace release_id : (unit, string) result =
  let* release = Sol_cli_release_store.get ~ctx ~workspace ~release_id in
  Printf.printf
    "Rolling back %s to release %s\n%!"
    workspace
    release.Sol_cli_release.release_id;
  let* release_id_t = Sol_cli_release_id.of_string release.Sol_cli_release.release_id in
  let current_migrations =
    List.map
      Sol_cli_plan_ids.Migration_file.to_string
      (Sol_cli_deployment_plan.discover_migrations ())
  in
  (* FEAT-075: the ordering itself -- refusal before mutation, pointer move
     only once the live set agrees -- lives in Sol_cli_rollback.execute, where
     it's tested. This wires the concrete, cluster-touching deps. *)
  let deps : Sol_cli_rollback.transaction_deps =
    { apply = apply_specs ~ctx ~release ~release_id_t
    ; live_workloads =
        (fun () ->
          Sol_cli_rollback.live_workloads
            ~ctx
            ~workspace:release.Sol_cli_release.workspace)
    ; move_pointer = (fun () -> Sol_cli_release_store.move_pointer ~ctx release)
    ; verify_pointer = (fun () -> Sol_cli_rollback.verify_pointer ~ctx ~release)
    }
  in
  match Sol_cli_rollback.execute ~release ~migrations_dir ~current_migrations ~deps with
  | Ok () ->
    Printf.printf
      "Verified: workloads and pointer both name release %s.\n%!"
      release.Sol_cli_release.release_id;
    Ok ()
  | Error msg -> Error msg
;;

(* FEAT-073: resolves RELEASE_ID/--commit/--scope down to one release id.
   Always echoed before [run_locked] does anything, including the
   unambiguous --commit case, so an operator can confirm before mutation. *)
let resolve_release_id ~ctx ~workspace ~target_string release_id commit scope
  : (string, string) result
  =
  match commit with
  | None ->
    (match scope with
     | Some _ ->
       Error
         "--scope only narrows --commit candidate resolution; pass --commit too, or a \
          release id directly."
     | None ->
       (match release_id with
        | Some id -> Ok id
        | None -> Error "pass a release id, or --commit <sha>."))
  | Some commit ->
    (match release_id with
     | Some _ -> Error "pass either a release id or --commit, not both."
     | None ->
       let* events = Sol_cli_deployment_store.list ~ctx ~workspace in
       let resolution =
         Sol_cli_rollback.resolve_commit ~commit ?scope ~target:target_string events
       in
       (match resolution with
        | Sol_cli_rollback.Commit_resolved release_id ->
          Printf.printf
            "%s\n%!"
            (Sol_cli_rollback.commit_resolution_to_string
               ~commit
               ~target:target_string
               ?scope
               resolution);
          Ok release_id
        | Commit_invalid _ | Commit_no_match | Commit_ambiguous _ ->
          Error
            (Sol_cli_rollback.commit_resolution_to_string
               ~commit
               ~target:target_string
               ?scope
               resolution)))
;;

let run ~ctx ~target_string release_id commit scope =
  let workspace = workspace_name () in
  match resolve_release_id ~ctx ~workspace ~target_string release_id commit scope with
  | Error msg ->
    Printf.eprintf "error: %s\n%!" msg;
    exit 1
  | Ok release_id ->
    (match
       Sol_cli_boundary_lease.with_boundary_lease
         ~ctx
         ~workspace
         ~holder:Sol_cli_boundary_lease.Rollback
         ~ttl:ttl_s
         ~wait_s
         (fun _lease -> run_locked ~ctx ~workspace release_id)
     with
     | Ok () -> ()
     | Error msg ->
       Printf.eprintf "error: %s\n%!" msg;
       exit 1)
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let release_id_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info
        []
        ~docv:"RELEASE_ID"
        ~doc:
          "The release id to restore, e.g. r-1a2b3c4d5e6f7890. Omit when using --commit.")
;;

let commit_arg =
  Arg.(
    value
    & opt (some string) None
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
    & opt (some string) None
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
        run
          ~ctx:
            (Cmd_destination.or_exit
               (Cmd_destination.resolve ~command:"rollback" ~local:false ~target))
          ~target_string:(Option.value target ~default:"local")
          release_id
          commit
          scope)
      $ release_id_arg
      $ commit_arg
      $ scope_arg
      $ Cmd_destination.target_arg)
;;

(* FEAT-063: the local form -- the same operation with the destination named
   literally as Sol's own cluster instead of resolved from --target. *)
let local_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Restore a recorded release boundary on the local cluster.")
    Term.(
      const (fun release_id commit scope ->
        run ~ctx:Cmd_destination.local ~target_string:"local" release_id commit scope)
      $ release_id_arg
      $ commit_arg
      $ scope_arg)
;;
