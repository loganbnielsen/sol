open Cmdliner
open Result.Syntax

(* Per-workspace table name avoids version-number collisions when multiple
   workspaces share one local Postgres instance; --table always overrides it. *)
let default_table_name =
  let cwd_name = Filename.basename (Sys.getcwd ()) in
  let buf = Buffer.create (String.length cwd_name) in
  cwd_name
  |> String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    then Buffer.add_char buf c
    else if c >= 'A' && c <= 'Z'
    then Buffer.add_char buf (Char.lowercase_ascii c)
    else Buffer.add_char buf '_');
  Printf.sprintf "sol_%s_schema_migrations" (Buffer.contents buf)
;;

let cluster_pg_exists ~ctx () =
  Result.is_ok
    (Sol_cli_kubectl.get
       ~ctx
       ~resource:"svc"
       ~name:"postgresql"
       ~namespace:"postgresql"
       ~output:"name")
;;

(* Start a background port-forward to cluster postgres and return the local URL.
   Registers at_exit cleanup so the forward is killed when the process exits. *)
let auto_forward_pg ~ctx () =
  Printf.printf "Forwarding postgresql (cluster) → localhost:15432 ...\n%!";
  let url = "postgresql://postgres:dev@localhost:15432/dev" in
  match
    Sol_cli_kubectl.temporary_port_forward
      ~ctx
      ~service:"postgresql"
      ~namespace:"postgresql"
      ~local_port:15432
      ~remote_port:5432
  with
  | Ok () -> Ok url
  | Error (Not_started e) ->
    Error ("could not start kubectl port-forward: " ^ Sol_cli_process.error_to_string e)
  | Error Not_ready ->
    Printf.eprintf "warning: port-forward did not become ready in time\n%!";
    Ok url
  | Error (Readiness_check_failed msg) ->
    Printf.eprintf "warning: port-forward readiness check failed: %s\n%!" msg;
    Ok url
;;

let get_postgres_url ~ctx () =
  match Sol_cli_string.env "POSTGRES_URL" with
  | Some u -> Ok u
  | None ->
    if cluster_pg_exists ~ctx ()
    then auto_forward_pg ~ctx ()
    else
      Error
        "POSTGRES_URL not set and no cluster postgres found.\n\
        \  Run 'sol local infra up' first, then retry."
;;

(* INFRA-044: Pg/caqti errors may reproduce their connection URI verbatim.
   Rendering through this boundary inside the migration runner is essential:
   scrubbing only the parent CLI's copy would leave the credential in the
   Kubernetes Job's own logs and in every sink that collects them. *)
let pg_error_to_string ~url error =
  Sol_cli_redaction.connection_error ~url (Pg_error.to_string error)
;;

let with_pool url f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
      | Error e -> Error ("cannot connect to database: " ^ pg_error_to_string ~url e)
      | Ok pool -> f ~fs:env#fs pool))
;;

(* ── apply ───────────────────────────────────────────────────────────────── *)

(* Print SQL files from [dir] in order without connecting to the database.
   Used by --dry-run to let operators preview migration SQL before applying. *)
let print_pending_sql dir =
  let migration_ext = ".sql" in
  let down_ext = ".down.sql" in
  let* files =
    match Sys.readdir dir with
    | exception Sys_error msg -> Error ("cannot read migrations dir: " ^ msg)
    | arr ->
      Ok
        (Array.to_list arr
         |> List.filter (fun f ->
           Filename.check_suffix f migration_ext && not (Filename.check_suffix f down_ext))
         |> List.sort String.compare)
  in
  (match files with
   | [] -> Printf.printf "(no migration files found in %s)\n" dir
   | files ->
     files
     |> List.iter (fun fname ->
       let path = Filename.concat dir fname in
       let content = In_channel.with_open_text path In_channel.input_all in
       Printf.printf "-- %s\n%s\n\n" fname content));
  Ok ()
;;

let run_apply_local ~ctx dir table dry_run =
  if dry_run
  then print_pending_sql dir
  else
    let* url = get_postgres_url ~ctx () in
    with_pool url (fun ~fs pool ->
      Printf.printf "Applying migrations from %s...\n%!" dir;
      let* () =
        Migration.apply ~table pool ~dir ~fs |> Result.map_error (pg_error_to_string ~url)
      in
      Printf.printf "Done.\n";
      Ok ())
;;

(* ── in-cluster migration Job (FRIC-012) ────────────────────────────────────
   A real deployment's Postgres (RDS, etc.) is correctly not reachable from
   outside the VPC -- confirmed live during DOGFOOD-011 (a 2-minute
   Connection timed out running sol migrate from an operator's laptop, with
   no network path at all, not a misconfiguration). Rather than punching a
   hole in that security posture or requiring every operator/CI runner to
   set up their own bastion/VPN, run the exact same Migration.apply logic
   from a one-shot Kubernetes Job inside the cluster, where the security
   group already allows access. This reuses infrastructure Sol already
   owns (the cluster, the workspace's runtime secret) instead of adding a
   new standing component, and generalizes to CI for free -- a GitHub
   Actions runner has the same external-network problem a laptop does, and
   can't hold an SSM session open the way an interactive operator could. *)

(* Same opam-pin/base-image block cli/lib/base/sol_cli_scaffold_templates.ml's
   tpl_dockerfile and the example workspace Dockerfiles use, trimmed to just
   what cli/bin/main.exe itself links (see cli/bin/dune) -- kept in
   sync by hand, same as every other place this block is duplicated. *)
let read_migration_files dir =
  let ext = ".sql" in
  match Sys.readdir dir with
  | exception Sys_error msg -> Error ("cannot read migrations dir: " ^ msg)
  | arr ->
    (* REFAC-131: a file is carried into a ConfigMap, and YAML cannot hold a NUL
       character; refuse the file by name rather than let it be truncated. *)
    let read fname =
      let content =
        In_channel.with_open_text (Filename.concat dir fname) In_channel.input_all
      in
      if String.contains content '\000'
      then
        Error
          (Printf.sprintf
             "migration %s contains a NUL character, which a ConfigMap cannot carry"
             fname)
      else Ok (fname, content)
    in
    Array.to_list arr
    |> List.filter (fun f -> Filename.check_suffix f ext)
    |> List.sort String.compare
    |> List.fold_left
         (fun acc fname ->
            let* files = acc in
            let* file = read fname in
            Ok (file :: files))
         (Ok [])
    |> Result.map List.rev
;;

(* DEC-038 §6 / INFRA-058: the operator's diagnostic grant follows the workload,
   not this command's scope, so reconcile it across every namespace that holds a
   Sol-managed workload. RBAC only -- it writes RoleBindings and nothing else.

   A failure here is a warning, not fatal: a deployment must not be blocked by a
   read-only grant. But it is never silent -- the warning names what could not be
   established and what it costs, because a diagnostic capability that quietly
   did not appear is the failure mode this whole line of work exists to remove. *)
let reconcile_operator_bindings_warn ~ctx ~workspace ~services =
  Sol_cli_substrate.reconcile_operator_bindings ~ctx ~workspace ~services
  |> Result.iter_error (fun msg ->
    Printf.eprintf
      "warning: could not establish the operator's diagnostic RoleBindings: %s\n\
       The operator identity will not be able to read this workspace's workloads.\n\
       %!"
      msg)
;;

let registry_of ~(target_cfg : Sol_cli_config.target) ~override ~how_to_set =
  match override, target_cfg.registry with
  | Some r, _ | None, Some r -> Ok r
  | None, None -> Error ("no registry configured for this target -- " ^ how_to_set)
;;

(* REFAC-139, part A: the Job is Sol_cli_migration_job's; this decides what its
   outcome means for `apply` and renders it. *)
let run_apply_in_cluster ~ctx ~target ~dir ~table ~registry_override =
  let* cfg =
    Sol_cli_config.load_for_target ~target
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let registry =
    registry_of
      ~target_cfg:cfg.target
      ~override:registry_override
      ~how_to_set:"pass --registry or set target.registry in sol.yml."
  in
  let workspace = Filename.basename (Sys.getcwd ()) in
  let* facts = Sol_cli_workspace_model.load_cwd () in
  let services = Sol_cli_workspace_model.services facts in
  let* namespace, k8s_name =
    Sol_cli_migration_job.namespace_and_repository ~workspace ~services
  in
  (* HARDEN-002 run 2, finding 8: the Job runs in this namespace and reads the
     runtime Secret, so establish both before submitting it. Doing it here is what
     makes a fresh target's first `sol migrate apply` possible. *)
  let* () = Sol_cli_substrate.ensure ~ctx ~namespaces:[ namespace ] in
  reconcile_operator_bindings_warn ~ctx ~workspace ~services;
  let* files = read_migration_files dir in
  if files = []
  then (
    Printf.printf "(no migration files found in %s -- nothing to do)\n" dir;
    Ok ())
  else
    let* image = Sol_cli_migration_job.runner_image ~registry ~workspace ~k8s_name in
    let* job =
      Sol_cli_migration_job.submit
        ~ctx
        ~namespace
        ~name_prefix:"sol-migrate"
        ~label:""
        ~image
        ~args:[ "migrate"; "apply"; "--dir"; "/migrations"; "--table"; table ]
        ~files
    in
    Printf.printf
      "Submitting migration Job %s in namespace %s...\n%!"
      job.job_name
      namespace;
    let outcome = Sol_cli_migration_job.wait ~ctx ~interval_s:2. ~attempts:150 job in
    Printf.printf "\n--- migration Job logs (%s) ---\n%!" job.job_name;
    (match Sol_cli_migration_job.logs ~ctx job with
     | Ok logs ->
       print_string
         (match Sol_cli_string.env "POSTGRES_URL" with
          | Some url -> Sol_cli_redaction.connection_error ~url logs
          | None -> logs)
     | Error e -> Printf.eprintf "warning: could not fetch job logs: %s\n" e);
    Printf.printf "--- end logs ---\n\n%!";
    (match outcome with
     | Timed_out s ->
       Printf.eprintf "error: migration Job did not complete within %.0fs\n" s
     | Unstartable { reason; detail } ->
       Printf.eprintf
         "error: migration Job cannot start: %s%s\n"
         reason
         (Option.fold detail ~none:"" ~some:(Printf.sprintf " (%s)"))
     | Succeeded | Failed -> ());
    Sol_cli_migration_job.cleanup ~ctx job;
    match outcome with
    | Succeeded ->
      Printf.printf "Done.\n";
      Ok ()
    | Failed | Unstartable _ | Timed_out _ ->
      Error "migration Job failed -- see logs above."
;;

(* ── AUDIT-069: the deploy's read-only migration prerequisite ─────────────── *)

(* The result of the live prerequisite check. [Unavailable] and [Unsatisfied]
   both stop the deploy before workload mutation; [Unavailable] is the
   fail-closed answer when the check itself could not be performed. *)
type migration_verification =
  | No_migrations
  | Satisfied of int list
  | Unsatisfied of Sol_cli_migration.prerequisite list
  | Unavailable of string

(* Read the authoritative applied set from the target cluster with a
   short-lived, read-only Job. The Job runs `migrate status --json`, which only
   reads schema_migrations. Any failure to run the Job or read the table is an
   [Error] the caller treats as [Unavailable] -- never a reason to assume the
   schema is compatible. *)
(* REFAC-130: [services] is the workspace inventory the caller already read, so
   this does not read the workspace again to pick a namespace. *)
let read_applied_in_cluster ~ctx ~target ~workspace ~dir ~table ~services =
  let* cfg =
    Sol_cli_config.load_for_target ~target
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let registry =
    registry_of
      ~target_cfg:cfg.target
      ~override:None
      ~how_to_set:"set target.registry in sol.yml."
  in
  let* namespace, k8s_name =
    Sol_cli_migration_job.namespace_and_repository ~workspace ~services
  in
  (* HARDEN-002 run 2, finding 8: as for `apply`, the Job reads the runtime Secret. *)
  let* () = Sol_cli_substrate.ensure ~ctx ~namespaces:[ namespace ] in
  let* image = Sol_cli_migration_job.runner_image ~registry ~workspace ~k8s_name in
  let* files = read_migration_files dir in
  let* job =
    Sol_cli_migration_job.submit
      ~ctx
      ~namespace
      ~name_prefix:"sol-migrate-status"
      ~label:"status "
      ~image
      ~args:[ "migrate"; "status"; "--json"; "--dir"; "/migrations"; "--table"; table ]
      ~files
  in
  let result =
    match Sol_cli_migration_job.wait ~ctx ~interval_s:2. ~attempts:60 job with
    | Unstartable { reason; detail } ->
      Error
        (Printf.sprintf
           "migration-status Job cannot start: %s%s"
           reason
           (Option.fold detail ~none:"" ~some:(Printf.sprintf " (%s)")))
    | Timed_out s ->
      Error (Printf.sprintf "migration-status Job did not complete within %.0fs" s)
    | Failed -> Error "migration-status Job failed -- see the Job logs"
    | Succeeded ->
      (match Sol_cli_migration_job.logs ~ctx job with
       | Error e -> Error ("could not read migration-status Job logs: " ^ e)
       | Ok logs ->
         (* The Job prints only the JSON body, but take the first `{`..last `}` so
            a stray log line cannot break the parse of an otherwise valid report. *)
         let text = String.trim logs in
         let text =
           match String.index_opt text '{', String.rindex_opt text '}' with
           | Some i, Some j when j > i -> String.sub text i (j - i + 1)
           | _ -> text
         in
         Sol_cli_migration.parse_status_json text)
  in
  (* INFRA-040: this check is read-only, so a success tidies up after itself. A
     failure must not delete the only record of why it failed: the evidence goes
     into the deploy's own output, and the Job is kept so it can still be read. *)
  (match result with
   | Ok _ -> Sol_cli_migration_job.cleanup ~ctx job
   | Error _ ->
     Sol_cli_migration_job.evidence ~ctx job
     |> Option.iter (Printf.eprintf "\nmigration-status Job evidence:\n%s\n%!");
     Printf.eprintf
       "\n\
        The failing Job is kept for inspection:\n\
       \  kubectl logs job/%s -n %s\n\
       \  kubectl delete job/%s configmap/%s -n %s\n\
        %!"
       job.job_name
       namespace
       job.job_name
       job.configmap_name
       namespace);
  result
;;

(* The prerequisite check the deploy path runs after the static preflight and
   before any workload mutation. [services] is the workspace inventory the
   deploying command already read (REFAC-130). *)
let verify_migration_prerequisite ~ctx ~target ~workspace ~dir ~services =
  match Sol_cli_migration.required ~dir with
  | Error e -> Unavailable e
  | Ok [] -> No_migrations
  | Ok required ->
    let table = Sol_cli_migration.table_name ~workspace in
    (match read_applied_in_cluster ~ctx ~target ~workspace ~dir ~table ~services with
     | Error e -> Unavailable e
     | Ok applied ->
       (match Sol_cli_migration.unsatisfied ~required ~applied with
        | [] -> Satisfied applied
        | missing -> Unsatisfied missing))
;;

(* BUG-041: every entry point that hands [dir] to the runner validates it with the
   same rule the deploy gate uses first, so a shared version stops here instead of
   being applied once and skipped once. *)
let require_valid_migrations dir = Sol_cli_migration.required ~dir |> Result.map ignore

(* ── status ──────────────────────────────────────────────────────────────── *)

let run_status ~ctx ?(json = false) dir table () =
  let* () = require_valid_migrations dir in
  let* url = get_postgres_url ~ctx () in
  with_pool url (fun ~fs pool ->
    let* rows =
      Migration.status ~table pool ~dir ~fs |> Result.map_error (pg_error_to_string ~url)
    in
    Ok
      (if json
       then
         print_endline
           (Sol_cli_migration.status_json
              ~table
              (rows
               |> List.map (fun (s : Migration.status) -> s.version, s.name, s.applied_at)
              ))
       else (
         Printf.printf "%-6s  %-30s  %s\n" "VER" "NAME" "APPLIED AT";
         Printf.printf "%s\n" (String.make 60 '-');
         rows
         |> List.iter (fun (s : Migration.status) ->
           Printf.printf
             "%-6d  %-30s  %s\n"
             s.version
             s.name
             (Option.value ~default:"(pending)" s.applied_at)))))
;;

(* ── rollback ────────────────────────────────────────────────────────────── *)

let run_rollback ~ctx dir table () =
  let* () = require_valid_migrations dir in
  let* url = get_postgres_url ~ctx () in
  with_pool url (fun ~fs pool ->
    let* () =
      Migration.rollback ~table pool ~dir ~fs
      |> Result.map_error (pg_error_to_string ~url)
    in
    Printf.printf "Rolled back.\n";
    Ok ())
;;

(* ── apply dispatch: local direct-connect vs in-cluster Job ────────────────── *)

let run_apply ~ctx dir table dry_run target registry =
  let* () = require_valid_migrations dir in
  if dry_run
  then print_pending_sql dir
  else (
    match target with
    | None -> run_apply_local ~ctx dir table dry_run
    | Some target ->
      run_apply_in_cluster ~ctx ~target ~dir ~table ~registry_override:registry)
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

(* FEAT-063: a named target supplies the destination; the no-target form is the
   local dev path and uses the literal local cluster. *)
let run_apply_term dir table dry_run target registry =
  Sol_cli_exit.exit_on
    (let* ctx =
       match target with
       | Some _ -> Cmd_destination.remote ~command:"migrate" target
       | None -> Ok Cmd_destination.local
     in
     run_apply ~ctx dir table dry_run target registry |> Sol_cli_exit.of_msg)
;;

let dir_arg =
  Arg.(
    value
    & opt Sol_cli_args.text "db/migrations"
    & info
        [ "dir" ]
        ~docv:"DIR"
        ~doc:"Directory containing migration SQL files (default: db/migrations)")
;;

let table_arg =
  Arg.(
    value
    & opt Sol_cli_args.text default_table_name
    & info
        [ "table" ]
        ~docv:"TABLE"
        ~doc:
          "Migration tracking table name (default: sol_<workspace>_schema_migrations; \
           override with this flag to share a table across workspaces)")
;;

let dry_run_flag =
  Arg.(
    value
    & flag
    & info [ "dry-run" ] ~doc:"Print pending migration SQL to stdout without applying")
;;

let target_arg =
  Arg.(
    value
    & pos 0 (some Sol_cli_args.text) None
    & info
        []
        ~docv:"TARGET"
        ~doc:
          "Deployment target path: <env>/<provider>/<region>. When given, migrations run \
           from a one-shot Kubernetes Job inside the target's cluster instead of \
           connecting directly from this machine — required for any real deployment \
           whose database (e.g. RDS) isn't reachable from outside its network by design \
           (FRIC-012). Omit for the local dev cluster, which remains directly reachable \
           via kubectl port-forward.")
;;

let registry_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "registry" ]
        ~docv:"URL"
        ~doc:
          "Container registry to push the migration runner image to. Omit to fall back \
           to the resolved target's own registry. Only meaningful together with TARGET.")
;;

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply all pending migrations (default subcommand)")
    Term.(
      const run_apply_term
      $ dir_arg
      $ table_arg
      $ dry_run_flag
      $ target_arg
      $ registry_arg)
;;

let json_flag =
  Arg.(
    value
    & flag
    & info
        [ "json" ]
        ~doc:
          "Emit the status as JSON (the machine-readable form the deploy path's \
           read-only prerequisite check consumes)")
;;

let status_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show per-file applied/pending status")
    Term.(
      const (fun dir table json ->
        Sol_cli_exit.exit_on
          (run_status ~ctx:Cmd_destination.local ~json dir table () |> Sol_cli_exit.of_msg))
      $ dir_arg
      $ table_arg
      $ json_flag)
;;

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Roll back the last applied migration")
    Term.(
      const (fun dir table ->
        Sol_cli_exit.exit_on
          (run_rollback ~ctx:Cmd_destination.local dir table () |> Sol_cli_exit.of_msg))
      $ dir_arg
      $ table_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "migrate" ~doc:"Run database migrations against POSTGRES_URL")
    ~default:
      Term.(
        const run_apply_term
        $ dir_arg
        $ table_arg
        $ dry_run_flag
        $ target_arg
        $ registry_arg)
    [ apply_cmd; status_cmd; rollback_cmd ]
;;

(* FEAT-063: the local form -- migrations against Sol's own cluster. *)
let local_cmd =
  Cmd.v
    (Cmd.info "migrate" ~doc:"Apply migrations against the local cluster's Postgres")
    Term.(
      const (fun dir table dry_run registry ->
        Sol_cli_exit.exit_on
          (run_apply ~ctx:Cmd_destination.local dir table dry_run None registry
           |> Sol_cli_exit.of_msg))
      $ dir_arg
      $ table_arg
      $ dry_run_flag
      $ registry_arg)
;;
