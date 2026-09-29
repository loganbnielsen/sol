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

let read_json path =
  match In_channel.with_open_bin path In_channel.input_all with
  | text ->
    (match Yojson.Safe.from_string text with
     | json -> Ok json
     | exception Yojson.Json_error msg -> Error (Printf.sprintf "%s: %s" path msg))
  | exception Sys_error msg -> Error msg
;;

let string_member key json = Sol_cli_json.field [ key ] json |> Sol_cli_json.string

let string_list = function
  | `List entries ->
    List.filter_map
      (function
        | `String s -> Some s
        | _ -> None)
      entries
  | _ -> []
;;

let workspaces_of json =
  match Sol_cli_json.field [ "workspaces" ] json with
  | `Assoc fields ->
    (match List.assoc_opt "packages" fields with
     | Some packages -> string_list packages
     | None -> [])
  | workspaces -> string_list workspaces
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

let package_json ~root dir = read_json (Filename.concat (join root dir) "package.json")

let npm_project_root ~root ~unit_dir ~package_name:_ =
  let rec up dir =
    if String.equal dir "" || String.equal dir "."
    then None
    else (
      let parent = Filename.dirname dir in
      let parent = if String.equal parent "." then "" else parent in
      let relative_dir = relative_under ~prefix:parent unit_dir in
      match package_json ~root parent with
      | Ok json
        when List.exists (fun entry -> declares ~entry ~relative_dir) (workspaces_of json)
        -> Some parent
      | _ -> up parent)
  in
  match up unit_dir with
  | Some npm_root -> npm_root
  | None -> unit_dir
;;

let entry_in_unit ~root ~unit_dir ~package_json =
  match Option.bind package_json (string_member "main") with
  | Some main -> main
  | None ->
    let out_dir =
      match read_json (Filename.concat (join root unit_dir) "tsconfig.json") with
      | Ok json ->
        Sol_cli_json.field [ "compilerOptions"; "outDir" ] json
        |> Sol_cli_json.string
        |> Option.value ~default:"dist"
      | Error _ -> "dist"
    in
    Filename.concat out_dir "index.js"
;;

let recipe_of_ocaml (svc : Sol_cli_manifest.service) =
  let dir = svc.Sol_cli_manifest.dir in
  Ok
    { label = label svc
    ; language = Sol_cli_compat.Ocaml
    ; build = None
    ; launch = { argv = [ "_build/default/" ^ dir ^ "/bin/main.exe" ]; cwd = "" }
    ; artifact = dir ^ "/bin/main.exe"
    }
;;

let recipe_of_typescript ~root (svc : Sol_cli_manifest.service) =
  let unit_dir = svc.Sol_cli_manifest.dir in
  let* package =
    match package_json ~root unit_dir with
    | Ok json -> Ok json
    | Error msg ->
      Error
        (Printf.sprintf
           "declares language: typescript, but its package.json could not be read (%s)"
           msg)
  in
  let* package_name =
    match string_member "name" package with
    | Some name -> Ok name
    | None ->
      Error
        "declares language: typescript, but its package.json declares no name, so there \
         is no npm package to build"
  in
  let npm_root = npm_project_root ~root ~unit_dir ~package_name in
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
  let entry = entry_in_unit ~root ~unit_dir ~package_json:(Some package) in
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
    }
;;

let recipe ~root (svc : Sol_cli_manifest.service) language =
  match language with
  | Sol_cli_compat.Ocaml -> recipe_of_ocaml svc
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

let dev_env =
  [ "KAFKA_BROKERS", "localhost:9092"
  ; "SCHEMA_REGISTRY_URL", "http://localhost:8081"
  ; "REDPANDA_ADMIN_URL", "http://localhost:9644"
  ; "POSTGRES_URL", "postgresql://postgres:dev@localhost:5432/dev"
  ; "LOKI_URL", "http://localhost:3100"
  ; "PUSHGATEWAY_URL", "http://localhost:9091"
  ; "TEMPO_URL", "http://localhost:4318"
  ; "KAFKA_SECURITY_PROTOCOL", "plaintext"
  ]
;;
