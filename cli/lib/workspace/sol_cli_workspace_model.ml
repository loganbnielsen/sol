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
  ; declared : Sol_cli_config.service list
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; migrations : migration list
  ; events : (string * Sol_cli_toml.event_decl) list
  ; targets : string list
  }

let services t =
  t.workloads
  |> List.filter_map (fun w -> if w.has_dockerfile then Some w.service else None)
;;

let workloads t = t.workloads
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

type declaration_issue =
  { service_name : string
  ; domain : string option
  ; path : string
  ; severity : [ `Error | `Warning ]
  ; message : string
  }

let declared_domain (s : Sol_cli_config.service) =
  match s.path with
  | Some p ->
    (match String.split_on_char '/' p with
     | [ "app"; domain; _ ] when domain <> "" -> Some domain
     | _ -> None)
  | None -> None
;;

let primitive_of_declared_type = function
  | "http" | "svc" | "service" -> Some Sol_cli_manifest.Svc
  | "worker" -> Some Sol_cli_manifest.Worker
  | "fn" | "function" -> Some Sol_cli_manifest.Fn
  | _ -> None
;;

let declaration_issue ?domain ~service_name ~severity ~path message =
  { service_name; domain; path; severity; message }
;;

let declaration_issues ~(scan : Sol_cli_manifest.workspace_scan) declared =
  let unexpected_dirs =
    List.map (fun (_, _, dir) -> dir) scan.Sol_cli_manifest.unexpected
  in
  let found_by_name name =
    List.find_opt
      (fun ((svc : Sol_cli_manifest.service), _) ->
         String.equal svc.Sol_cli_manifest.name name)
      scan.Sol_cli_manifest.workloads
  in
  declared
  |> List.filter (fun (s : Sol_cli_config.service) -> not s.omit)
  |> List.filter_map (fun (s : Sol_cli_config.service) ->
    match found_by_name s.name with
    | Some (workload, _) ->
      let domain = Some workload.Sol_cli_manifest.domain in
      (match s.path with
       | Some declared_path when not (String.equal declared_path workload.dir) ->
         Some
           (declaration_issue
              ?domain
              ~service_name:s.name
              ~severity:`Error
              ~path:declared_path
              (Printf.sprintf
                 "sol.yml service %s declares this path, but its unit is at %s"
                 s.name
                 workload.dir))
       | declared_path ->
         (match s.typ with
          | Some declared_type ->
            (match primitive_of_declared_type declared_type with
             | Some primitive when primitive <> workload.primitive ->
               Some
                 (declaration_issue
                    ?domain
                    ~service_name:s.name
                    ~severity:`Warning
                    ~path:(Option.value declared_path ~default:workload.dir)
                    (Printf.sprintf
                       "sol.yml service %s declares type %S, but its unit is a %s \
                        workload"
                       s.name
                       declared_type
                       (Sol_cli_manifest.primitive_label workload.primitive)))
             | _ -> None)
          | None -> None))
    | None ->
      let no_unit declared_path =
        declaration_issue
          ?domain:(declared_domain s)
          ~service_name:s.name
          ~severity:`Error
          ~path:declared_path
          (Printf.sprintf
             "sol.yml service %s declares this path, but no unit directory exists there"
             s.name)
      in
      let right_suffix declared_path =
        declaration_issue
          ?domain:(declared_domain s)
          ~service_name:s.name
          ~severity:`Error
          ~path:declared_path
          (Printf.sprintf
             "sol.yml service %s declares this path, but its directory name carries no \
              *_svc, *_worker or *_fn suffix"
             s.name)
      in
      (match s.path with
       | Some declared_path ->
         let leaf = Filename.basename declared_path in
         if List.mem declared_path unexpected_dirs
         then Some (right_suffix declared_path)
         else if Sol_cli_manifest.primitive_of_suffix leaf = None
         then Some (right_suffix declared_path)
         else if not (String.equal leaf s.name)
         then
           Some
             (declaration_issue
                ?domain:(declared_domain s)
                ~service_name:s.name
                ~severity:`Error
                ~path:declared_path
                (Printf.sprintf
                   "sol.yml service %s declares this path, but its directory is named %s"
                   s.name
                   leaf))
         else Some (no_unit declared_path)
       | None ->
         Some
           (declaration_issue
              ~service_name:s.name
              ~severity:`Error
              ~path:"sol.yml"
              (Printf.sprintf
                 "sol.yml declares service %s, but there is no app/<domain>/%s unit \
                  directory"
                 s.name
                 s.name))))
;;

let scan_of (t : t) : Sol_cli_manifest.workspace_scan =
  { Sol_cli_manifest.workloads =
      List.map (fun w -> w.service, w.has_dockerfile) t.workloads
  ; unexpected = t.unexpected
  }
;;

let declaration_issues_of t = declaration_issues ~scan:(scan_of t) t.declared

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
  let* migrations =
    Sol_cli_workspace_scan.discover_migrations ~root ()
    |> Result.map (List.map (migration_of_file ~root))
  in
  let* events =
    Sol_cli_workspace_scan.discover_events ~root ()
    |> Result.map_error Sol_cli_toml.parse_error_to_string
  in
  let* schema_subjects = Sol_cli_workspace_scan.discover_schema_subjects ~root () in
  Ok
    { root
    ; app_dir = Option.map (fun _ -> Filename.concat root "app") scanned
    ; workloads
    ; unexpected =
        (match scanned with
         | None -> []
         | Some scan -> scan.unexpected)
    ; declared
    ; topics
    ; schema_subjects
    ; migrations
    ; events
    ; targets
    }
;;

let load_cwd () =
  match Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ()) with
  | Error e -> Error (Sol_cli_workspace.workspace_error_to_string e)
  | Ok root -> load ~root
;;
