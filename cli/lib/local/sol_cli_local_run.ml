open Result.Syntax

type command =
  { argv : string list
  ; cwd : string
  }

type recipe =
  { label : string
  ; language : Sol_cli_compat.language
  ; build : command option
  ; launch : command
  ; artifact : string
  ; env : (string * string) list
  }

type plan =
  { builds : command list
  ; launches : recipe list
  }

let label (svc : Sol_cli_manifest.service) = svc.domain ^ "/" ^ svc.name

let join root path =
  match path with
  | "" | "." -> root
  | path -> Filename.concat root path
;;

let relative_under ~prefix dir =
  match prefix with
  | "" | "." -> dir
  | prefix ->
    if String.equal dir prefix
    then ""
    else
      String.sub
        dir
        (String.length prefix + 1)
        (String.length dir - String.length prefix - 1)
;;

let read_json_opt path =
  match In_channel.with_open_bin path In_channel.input_all with
  | text ->
    (match Yojson.Safe.from_string text with
     | json -> Ok (Some json)
     | exception Yojson.Json_error msg -> Error (Printf.sprintf "%s: %s" path msg))
  | exception Sys_error msg ->
    if Sys.file_exists path then Error (Printf.sprintf "%s: %s" path msg) else Ok None
;;

let optional_string_field ~what json key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | None | Some `Null -> Ok None
     | Some (`String value) -> Ok (Some value)
     | Some _ -> Error (Printf.sprintf "%s: %s must be text" what key))
  | _ -> Error (Printf.sprintf "%s: expected a JSON object" what)
;;

let strings_field ~what value =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | `String item :: rest -> go (item :: acc) rest
    | _ -> Error (Printf.sprintf "%s must be a list of strings" what)
  in
  match value with
  | `List entries -> go [] entries
  | _ -> Error (Printf.sprintf "%s must be a list of strings" what)
;;

let workspaces_of json =
  match Sol_cli_json.field [ "workspaces" ] json with
  | `Null -> Ok []
  | `Assoc fields ->
    (match List.assoc_opt "packages" fields with
     | None | Some `Null -> Ok []
     | Some packages -> strings_field ~what:"workspaces.packages" packages)
  | workspaces -> strings_field ~what:"workspaces" workspaces
;;

let glob_matches pattern path =
  let plen = String.length pattern
  and slen = String.length path in
  let rec go p s =
    if p = plen
    then s = slen
    else (
      match pattern.[p] with
      | '*' when p + 1 < plen && pattern.[p + 1] = '*' ->
        let rec any s' = s' <= slen && (go (p + 2) s' || any (s' + 1)) in
        any s
      | '*' ->
        let rec any s' =
          s' <= slen && (go (p + 1) s' || (s' < slen && path.[s'] <> '/' && any (s' + 1)))
        in
        any s
      | '?' -> s < slen && path.[s] <> '/' && go (p + 1) (s + 1)
      | c -> s < slen && path.[s] = c && go (p + 1) (s + 1))
  in
  go 0 0
;;

let normalize_workspace_entry entry =
  let entry =
    if String.length entry >= 2 && String.sub entry 0 2 = "./"
    then String.sub entry 2 (String.length entry - 2)
    else entry
  in
  let rec strip_trailing s =
    let len = String.length s in
    if len > 0 && s.[len - 1] = '/' then strip_trailing (String.sub s 0 (len - 1)) else s
  in
  strip_trailing entry
;;

let declares ~entry ~relative_dir =
  let entry = normalize_workspace_entry entry in
  String.equal entry relative_dir || glob_matches entry relative_dir
;;

let npm_project_root ~root ~unit_dir =
  let rec up dir =
    if String.equal dir "" || String.equal dir "."
    then Ok None
    else (
      let parent = Filename.dirname dir in
      let parent = if String.equal parent "." then "" else parent in
      let relative_dir = relative_under ~prefix:parent unit_dir in
      let package_path = Filename.concat (join root parent) "package.json" in
      let* package = read_json_opt package_path in
      match package with
      | None -> up parent
      | Some json ->
        let* entries =
          workspaces_of json
          |> Result.map_error (fun msg -> Printf.sprintf "%s: %s" package_path msg)
        in
        if List.exists (fun entry -> declares ~entry ~relative_dir) entries
        then Ok (Some parent)
        else up parent)
  in
  match up unit_dir with
  | Ok (Some npm_root) -> Ok npm_root
  | Ok None -> Ok unit_dir
  | Error _ as error -> error
;;

let entry_in_unit ~root ~unit_dir ~package_path ~package_json =
  let* main = optional_string_field ~what:package_path package_json "main" in
  match main with
  | Some main -> Ok main
  | None ->
    let tsconfig_path = Filename.concat (join root unit_dir) "tsconfig.json" in
    let* tsconfig = read_json_opt tsconfig_path in
    let* out_dir =
      match tsconfig with
      | None -> Ok "dist"
      | Some json ->
        (match Sol_cli_json.field [ "compilerOptions" ] json with
         | `Null -> Ok "dist"
         | `Assoc fields ->
           (match List.assoc_opt "outDir" fields with
            | None | Some `Null -> Ok "dist"
            | Some (`String out_dir) -> Ok out_dir
            | Some _ ->
              Error
                (Printf.sprintf "%s: compilerOptions.outDir must be text" tsconfig_path))
         | _ ->
           Error (Printf.sprintf "%s: compilerOptions must be an object" tsconfig_path))
    in
    Ok (Filename.concat out_dir "index.js")
;;

let dev_registry_url = "http://localhost:8081"

let dev_env =
  [ "KAFKA_BROKERS", "localhost:9092"
  ; "SCHEMA_REGISTRY_URL", dev_registry_url
  ; "REDPANDA_ADMIN_URL", "http://localhost:9644"
  ; "POSTGRES_URL", "postgresql://postgres:dev@localhost:5432/dev"
  ; "LOKI_URL", "http://localhost:3100"
  ; "PUSHGATEWAY_URL", "http://localhost:9091"
  ; "TEMPO_URL", "http://localhost:4318"
  ; "KAFKA_SECURITY_PROTOCOL", "plaintext"
  ]
;;

let dev_identity ~root (svc : Sol_cli_manifest.service) =
  Sol_cli_manifest.identity_env
    ~workspace:(Filename.basename root)
    ~domain:svc.Sol_cli_manifest.domain
    ~service:(Sol_cli_kubernetes_name.normalize svc.Sol_cli_manifest.name)
    ~primitive:(Sol_cli_manifest.primitive_label svc.Sol_cli_manifest.primitive)
    ()
;;

let recipe_of_ocaml ~root (svc : Sol_cli_manifest.service) =
  let dir = svc.Sol_cli_manifest.dir in
  Ok
    { label = label svc
    ; language = Sol_cli_compat.Ocaml
    ; build = None
    ; launch = { argv = [ "_build/default/" ^ dir ^ "/bin/main.exe" ]; cwd = "" }
    ; artifact = dir ^ "/bin/main.exe"
    ; env = dev_env @ dev_identity ~root svc
    }
;;

let recipe_of_typescript ~root (svc : Sol_cli_manifest.service) =
  let unit_dir = svc.Sol_cli_manifest.dir in
  let package_path = Filename.concat (join root unit_dir) "package.json" in
  let* package =
    match read_json_opt package_path with
    | Ok (Some json) -> Ok json
    | Ok None ->
      Error
        (Printf.sprintf
           "declares language: typescript, but its package.json could not be read (%s: \
            no such file)"
           package_path)
    | Error msg ->
      Error
        (Printf.sprintf
           "declares language: typescript, but its package.json could not be read (%s)"
           msg)
  in
  let* package_name =
    let* name = optional_string_field ~what:package_path package "name" in
    match name with
    | Some name -> Ok name
    | None ->
      Error
        "declares language: typescript, but its package.json declares no name, so there \
         is no npm package to build"
  in
  let* npm_root = npm_project_root ~root ~unit_dir in
  let* () =
    if Sys.file_exists (Filename.concat (join root npm_root) "node_modules")
    then Ok ()
    else
      Error
        (Printf.sprintf
           "has no installed dependencies; run `npm ci` in %s"
           (match npm_root with
            | "" | "." -> "."
            | dir -> dir))
  in
  let build =
    if String.equal npm_root unit_dir
    then { argv = [ "npm"; "run"; "build" ]; cwd = npm_root }
    else { argv = [ "npm"; "run"; "build"; "--workspace"; package_name ]; cwd = npm_root }
  in
  let* entry = entry_in_unit ~root ~unit_dir ~package_path ~package_json:package in
  Ok
    { label = label svc
    ; language = Sol_cli_compat.Typescript
    ; build = Some build
    ; launch =
        { argv =
            [ "node"; Filename.concat (relative_under ~prefix:npm_root unit_dir) entry ]
        ; cwd = npm_root
        }
    ; artifact = Filename.concat unit_dir entry
    ; env = dev_env @ dev_identity ~root svc
    }
;;

let recipe ~root (svc : Sol_cli_manifest.service) language =
  match language with
  | Sol_cli_compat.Ocaml -> recipe_of_ocaml ~root svc
  | Sol_cli_compat.Typescript -> recipe_of_typescript ~root svc
;;

let workload_of (facts : Sol_cli_workspace_model.t) (svc : Sol_cli_manifest.service) =
  List.find_opt
    (fun (w : Sol_cli_workspace_model.workload) ->
       String.equal w.Sol_cli_workspace_model.service.Sol_cli_manifest.domain svc.domain
       && String.equal w.Sol_cli_workspace_model.service.Sol_cli_manifest.name svc.name)
    facts.workloads
;;

let plan ~root ~facts services =
  let resolved =
    services
    |> List.map (fun svc ->
      match workload_of facts svc with
      | None -> Error (label svc, "is not part of this workspace")
      | Some workload ->
        (match workload.Sol_cli_workspace_model.language with
         | Some language ->
           (match recipe ~root svc language with
            | Ok recipe -> Ok recipe
            | Error message -> Error (label svc, message))
         | None ->
           Error
             ( label svc
             , Printf.sprintf
                 "declares no language; add `language: ocaml` (or typescript) under \
                  services.%s in sol.yml"
                 svc.name )))
  in
  match
    List.filter_map
      (function
        | Error e -> Some e
        | Ok _ -> None)
      resolved
  with
  | _ :: _ as errors -> Error errors
  | [] ->
    let recipes =
      List.filter_map
        (function
          | Ok r -> Some r
          | Error _ -> None)
        resolved
    in
    let dune_targets =
      recipes
      |> List.filter_map (fun r ->
        match r.language with
        | Sol_cli_compat.Ocaml -> Some r.artifact
        | Sol_cli_compat.Typescript -> None)
    in
    let ocaml_build =
      match dune_targets with
      | [] -> []
      | targets -> [ { argv = "dune" :: "build" :: targets; cwd = "" } ]
    in
    let unit_builds = List.filter_map (fun r -> r.build) recipes in
    Ok { builds = ocaml_build @ unit_builds; launches = recipes }
;;

let shell_line ?(prefix = "") (command : command) =
  let in_dir =
    match command.cwd with
    | "" | "." -> ""
    | cwd -> "cd " ^ Filename.quote cwd ^ " && "
  in
  prefix ^ in_dir ^ String.concat " " (List.map Filename.quote command.argv)
;;

let opam_env_prefix = "eval $(opam env 2>/dev/null) 2>/dev/null; "
let build_line command = shell_line ~prefix:opam_env_prefix command
let launch_line command = shell_line command
