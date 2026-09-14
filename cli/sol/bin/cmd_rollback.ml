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

let die fmt =
  Printf.ksprintf
    (fun msg ->
       Printf.eprintf "error: %s\n%!" msg;
       exit 1)
    fmt
;;

let run ~ctx release_id =
  let workspace = workspace_name () in
  (* resolve + load + validate *)
  let release =
    match Sol_cli_release_store.get ~ctx ~workspace ~release_id with
    | Ok release -> release
    | Error msg -> die "%s" msg
  in
  Printf.printf
    "Rolling back %s to release %s\n%!"
    workspace
    release.Sol_cli_release.release_id;
  (* Ownership check first: a GitOps/controller-owned release is not something a
     direct apply can safely roll back, so refuse before touching anything. *)
  (match Sol_cli_rollback.check_apply_mode ~release with
   | Error e -> die "%s" (Sol_cli_rollback.apply_mode_check_error_to_string e)
   | Ok () -> ());
  (* migration boundary check -- refused rollback must not touch the cluster,
     so this runs before any render/apply preparation. *)
  let current_migrations =
    List.map
      Sol_cli_plan_ids.Migration_file.to_string
      (Sol_cli_deployment_plan.discover_migrations ())
  in
  (match
     Sol_cli_rollback.check_migration_boundary
       ~release
       ~migrations_dir
       ~current_migrations
   with
   | Error e -> die "%s" (Sol_cli_rollback.migration_check_error_to_string e)
   | Ok () -> ());
  (* reconstruct: the proven historical decode, no ambient input. *)
  let specs =
    match Sol_cli_rollback.service_specs_of_release release with
    | Ok specs -> specs
    | Error msg -> die "%s" msg
  in
  let release_id_t =
    match Sol_cli_release_id.of_string release.Sol_cli_release.release_id with
    | Ok id -> id
    | Error msg -> die "%s" msg
  in
  (* render + apply. Kubernetes_live: a real apply to a live cluster reads
     secret values from this process's environment, exactly as sol up/sol
     deploy do for a direct (non-GitOps) apply -- the release record only
     ever carries secret key names, never values. GitOps-mode rollback
     (content and pointer travelling in one emitted commit) is not this
     pass's concern. *)
  (try
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
       specs
   with
   | Sol_cli_manifest.Deploy_failed msg -> die "%s" msg);
  (* Verify the live workload SET before declaring the pointer. The pointer is
     the declaration "this is now the current release"; it must not be written
     until the live workloads actually agree with it. A failure here therefore
     leaves the pointer untouched and never claims a transition that did not
     happen. Reported, never reconciled: rollback does not prune stale
     workloads, it refuses to call a hybrid state a success. *)
  (match
     Sol_cli_rollback.live_workloads ~ctx ~workspace:release.Sol_cli_release.workspace
   with
   | Error msg -> die "cannot verify rollback: %s" msg
   | Ok live ->
     let report = Sol_cli_rollback.verify_workloads ~release ~expected:specs ~live in
     if not (Sol_cli_rollback.workload_report_ok report)
     then (
       Printf.eprintf
         "%s\n%!"
         (Sol_cli_rollback.workload_report_to_string ~release report);
       die
         "rollback incomplete: live workloads do not match release %s; the \
          current-release pointer was left unchanged"
         release.Sol_cli_release.release_id));
  (* pointer move: only after every workload applied and the live set agrees. *)
  (match Sol_cli_release_store.move_pointer ~ctx release with
   | Error msg -> die "%s" msg
   | Ok () -> ());
  (* pointer verify: reported independently, never reconciled. *)
  let pointer = Sol_cli_rollback.verify_pointer ~ctx ~release in
  if Sol_cli_rollback.pointer_report_ok pointer
  then
    Printf.printf
      "Verified: workloads and pointer both name release %s.\n%!"
      release.Sol_cli_release.release_id
  else (
    Printf.eprintf
      "%s\n\
       rollback incomplete: the pointer was moved but does not read back as the restored \
       release; verify cluster state before relying on this rollback.\n\
       %!"
      (Sol_cli_rollback.pointer_report_to_string ~release pointer);
    exit 1)
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let release_id_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info
        []
        ~docv:"RELEASE_ID"
        ~doc:"The release id to restore, e.g. r-1a2b3c4d5e6f7890.")
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
      const (fun release_id target ->
        run
          ~ctx:
            (Cmd_destination.or_exit
               (Cmd_destination.resolve ~command:"rollback" ~local:false ~target))
          release_id)
      $ release_id_arg
      $ Cmd_destination.target_arg)
;;

(* FEAT-063: the local form -- the same operation with the destination named
   literally as Sol's own cluster instead of resolved from --target. *)
let local_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Restore a recorded release boundary on the local cluster.")
    Term.(
      const (fun release_id -> run ~ctx:Cmd_destination.local release_id) $ release_id_arg)
;;
