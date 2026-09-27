(* FEAT-103: what `sol local run` runs, per workload.

   Decisions only -- this module starts nothing, so the adapters are testable
   without a cluster or a process. The declared language (FEAT-104) picks the
   adapter; the unit's own toolchain metadata is read only once that is known.
   The interface rationale is in the .mli. *)

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

(* ── a unit's own toolchain metadata ─────────────────────────────────────── *)

(* [path] is workspace-root relative; [""] and ["."] both mean the root. *)
let join root path =
  match path with
  | "" | "." -> root
  | path -> Filename.concat root path
;;

(* [dir] with [prefix] removed, where [prefix] is an ancestor of [dir]; both are
   workspace-root relative. *)
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

let string_member key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None
;;

let string_list = function
  | `List entries ->
    List.filter_map
      (function
        | `String s -> Some s
        | _ -> None)
      entries
  | _ -> []
;;

(* npm accepts either `workspaces: [ ... ]` or `workspaces: { packages: [ ... ] }`. *)
let workspaces_of json =
  match Yojson.Safe.Util.member "workspaces" json with
  | `Assoc fields ->
    (match List.assoc_opt "packages" fields with
     | Some packages -> string_list packages
     | None -> [])
  | workspaces -> string_list workspaces
;;

(* A workspace entry names a directory (`order_svc`), a package (`order-svc`) or a
   glob; all three forms appear in the wild, and this repository's example uses
   the directory form while its package names differ (`order_svc` vs
   `order-svc`). *)
let declares ~entry ~package_name ~dir_name =
  String.equal entry package_name
  || String.equal entry dir_name
  || Sol_cli_string.contains ~needle:"*" entry
;;

let package_json ~root dir = read_json (Filename.concat (join root dir) "package.json")

(* The npm project a TypeScript unit builds in: the nearest ancestor whose
   package.json lists the unit as a workspace, else the unit's own directory
   (a standalone project). *)
let npm_project_root ~root ~unit_dir ~package_name =
  let dir_name = Filename.basename unit_dir in
  let rec up dir =
    if String.equal dir "" || String.equal dir "."
    then None
    else (
      let parent = Filename.dirname dir in
      let parent = if String.equal parent "." then "" else parent in
      match package_json ~root parent with
      | Ok json
        when List.exists
               (fun entry -> declares ~entry ~package_name ~dir_name)
               (workspaces_of json) -> Some parent
      | _ -> up parent)
  in
  match up unit_dir with
  | Some npm_root -> npm_root
  | None -> unit_dir
;;

(* The built entry, relative to the unit's own directory: the package's `main`
   when it declares one, else `<outDir>/index.js` -- the layout tsconfig
   declares, `dist` by default. A tsconfig that does not parse (JSONC, say)
   leaves the default in place; a wrong guess then fails naming the path rather
   than silently running nothing. *)
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

(* ── the adapters ────────────────────────────────────────────────────────── *)

let recipe_of_ocaml (svc : Sol_cli_manifest.service) =
  let dir = svc.Sol_cli_manifest.dir in
  Ok
    { label = label svc
    ; language = Sol_cli_compat.Ocaml
    ; build = None (* merged into one dune build by [plan] *)
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
    ; build =
        Some build
        (* The launch is `node <entry>`, never `npm run start`: the loop kills the
         process it started, and killing npm would leave the service behind. It
         runs where the unit's own instructions run it -- its npm project root --
         so the entry is named relative to that. *)
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

(* ── the plan ────────────────────────────────────────────────────────────── *)

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
    (* One dune build for every OCaml unit: concurrent dune invocations fight
       over the build lock, which is why the loop always built them together. *)
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
