type workload =
  { service : Sol_cli_manifest.service
  ; has_dockerfile : bool
  ; language : Sol_cli_compat.language option
  ; config : (Sol_cli_toml.t, Sol_cli_toml.parse_error) result
  }

type migration =
  { file : Sol_cli_plan_ids.Migration_file.t
  ; version : int option
  ; name : string option
  ; disposition : (Sol_cli_migration_disposition.t, string) result
  }

type t =
  { root : string
  ; app_dir : string option
  ; workloads : workload list
  ; unexpected : Sol_cli_manifest.unexpected list
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; migrations : migration list
  ; targets : string list
  }

let services t =
  t.workloads
  |> List.filter_map (fun w -> if w.has_dockerfile then Some w.service else None)
;;

let migration_files t = List.map (fun m -> m.file) t.migrations

let count_unapplied_migrations t =
  t.migrations
  |> List.filter (fun m ->
    not
      (Filename.check_suffix
         (Sol_cli_plan_ids.Migration_file.to_string m.file)
         ".down.sql"))
  |> List.length
;;

let language_of_services (declared : Sol_cli_config.service list) name =
  match
    List.find_opt (fun (s : Sol_cli_config.service) -> String.equal s.name name) declared
  with
  | Some (s : Sol_cli_config.service) -> s.language
  | None -> None
;;

let workload_of_manifest ~root ~declared (svc : Sol_cli_manifest.service) has_dockerfile =
  let sol_toml_path = Filename.concat root (Filename.concat svc.dir "sol.toml") in
  { service = svc
  ; has_dockerfile
  ; language = language_of_services declared svc.name
  ; config = Sol_cli_toml.load_result sol_toml_path
  }
;;

let migration_of_file ~root file =
  let filename = Sol_cli_plan_ids.Migration_file.to_string file in
  let path =
    Filename.concat root (Filename.concat Sol_cli_migration.default_dir filename)
  in
  let version, name =
    match Sol_cli_migration.parse_version filename with
    | Some (version, name) -> Some version, Some name
    | None -> None, None
  in
  { file; version; name; disposition = Sol_cli_migration_disposition.read_file ~path }
;;

let load ~root =
  let open Result.Syntax in
  let* scanned =
    match Sol_cli_manifest.scan_workspace ~root () with
    | Ok scan -> Ok (Some scan)
    | Error Sol_cli_manifest.Missing_app_dir -> Ok None
    | Error e -> Error (Sol_cli_manifest.discover_error_to_string e)
  in
  let* declared =
    Sol_cli_config.sol_yml_services ~root
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let* topics =
    Sol_cli_workspace_scan.discover_topics ~root ()
    |> Result.map_error Sol_cli_toml.parse_error_to_string
  in
  let* targets =
    Sol_cli_config.discover_target_paths ~root ()
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let workloads =
    match scanned with
    | None -> []
    | Some scan ->
      List.map
        (fun (svc, has_dockerfile) ->
           workload_of_manifest ~root ~declared svc has_dockerfile)
        scan.workloads
  in
  let migrations =
    Sol_cli_workspace_scan.discover_migrations ~root ()
    |> List.map (migration_of_file ~root)
  in
  Ok
    { root
    ; app_dir = Option.map (fun _ -> Filename.concat root "app") scanned
    ; workloads
    ; unexpected =
        (match scanned with
         | None -> []
         | Some scan -> scan.unexpected)
    ; topics
    ; schema_subjects = Sol_cli_workspace_scan.discover_schema_subjects ~root ()
    ; migrations
    ; targets
    }
;;

let load_cwd () =
  match Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ()) with
  | Error e -> Error (Sol_cli_workspace.workspace_error_to_string e)
  | Ok root -> load ~root
;;
