(* REFAC-139: the deploy's migration gate (AUDIT-069), and the pieces of the
   in-cluster runner it shares with `sol migrate apply`. It lived in
   `cmd_migrate.ml`, which made `sol deploy` depend on another command's module;
   the gate is a library rule, and both commands render its outcome. *)

open Result.Syntax

let migration_files dir =
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
let reconcile_operator_bindings ~ctx ~workspace ~services =
  Sol_cli_substrate.reconcile_operator_bindings ~ctx ~workspace ~services
  |> Result.iter_error (fun msg ->
    Sol_cli_report.warn
      "warning: could not establish the operator's diagnostic RoleBindings: %s\n\
       The operator identity will not be able to read this workspace's workloads."
      msg)
;;

let registry_of ~configured ~override ~how_to_set =
  match override, configured with
  | Some r, _ | None, Some r -> Ok r
  | None, None -> Error ("no registry configured for this target -- " ^ how_to_set)
;;

(* ── AUDIT-069: the deploy's read-only migration prerequisite ─────────────── *)

(* The result of the live prerequisite check. [Unavailable] and [Unsatisfied]
   both stop the deploy before workload mutation; [Unavailable] is the
   fail-closed answer when the check itself could not be performed. *)
type verification =
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
let read_applied ~ctx ~target ~workspace ~dir ~table ~services =
  let* cfg =
    Sol_cli_config.load_for_target ~target
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let registry =
    registry_of
      ~configured:cfg.target.registry
      ~override:None
      ~how_to_set:"set target.registry in sol.yml."
  in
  let* namespace, k8s_name =
    Sol_cli_migration_job.namespace_and_repository ~workspace ~services
  in
  (* HARDEN-002 run 2, finding 8: as for `apply`, the Job reads the runtime Secret. *)
  let* () = Sol_cli_substrate.ensure ~ctx ~namespaces:[ namespace ] in
  let* image = Sol_cli_migration_job.runner_image ~registry ~workspace ~k8s_name in
  let* files = migration_files dir in
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
     |> Option.iter (Sol_cli_report.err "\nmigration-status Job evidence:\n%s");
     Sol_cli_report.err
       "\n\
        The failing Job is kept for inspection:\n\
       \  kubectl logs job/%s -n %s\n\
       \  kubectl delete job/%s configmap/%s -n %s"
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
let verify ~ctx ~target ~workspace ~dir ~services =
  match Sol_cli_migration.required ~dir with
  | Error e -> Unavailable e
  | Ok [] -> No_migrations
  | Ok required ->
    let table = Sol_cli_migration.table_name ~workspace in
    (match read_applied ~ctx ~target ~workspace ~dir ~table ~services with
     | Error e -> Unavailable e
     | Ok applied ->
       (match Sol_cli_migration.unsatisfied ~required ~applied with
        | [] -> Satisfied applied
        | missing -> Unsatisfied missing))
;;
