type infra_requirements =
  { kafka : bool
  ; postgres : bool
  ; loki : bool
  ; prometheus : bool
  ; tempo : bool
  }

let workspace_file = "sol.yml"

type workspace_error =
  | Not_in_workspace
  | Nested_workspace of
      { outer : string
      ; inner : string
      }

let workspace_error_to_string = function
  | Not_in_workspace ->
    "not inside a Sol workspace (no sol.yml found)\n\n\
     A Sol workspace is identified by sol.yml.\n\
     Run this command from an existing Sol workspace, or create one with\n\
     `sol new workspace <name>`."
  | Nested_workspace { outer; inner } ->
    Printf.sprintf
      "nested Sol workspace is not supported\n\n\
       workspace:        %s\n\
       nested workspace: %s\n\n\
       Use sibling workspaces instead."
      outer
      inner
;;

let has_workspace_file dir =
  let path = Filename.concat dir workspace_file in
  Sys.file_exists path && not (Sys.is_directory path)
;;

let find_root ~dir =
  let rec go dir =
    if has_workspace_file dir
    then Some dir
    else (
      let parent = Filename.dirname dir in
      if parent = dir then None else go parent)
  in
  go dir
;;

let resolve ~dir =
  match find_root ~dir with
  | Some root -> Ok root
  | None -> Error Not_in_workspace
;;

let at_root path =
  match find_root ~dir:(Sys.getcwd ()) with
  | Some root -> Filename.concat root path
  | None -> path
;;

let workspace_name ~root = Filename.basename root
let root_or_dir ~dir = Option.value (find_root ~dir) ~default:dir
let name_from ~dir = workspace_name ~root:(root_or_dir ~dir)
let current_name () = name_from ~dir:(Sys.getcwd ())
let migrations_dir ~dir = Filename.concat (root_or_dir ~dir) Sol_cli_migration.default_dir
let migrations_table ~dir = Sol_cli_migration.table_name ~workspace:(name_from ~dir)

let ignored_dir name =
  name = "_build" || name = "node_modules" || name = "vendor" || name = "dist"
;;

let is_symlink path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_LNK; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false
;;

let validate ~root =
  let rec go dir =
    let entries =
      try Sys.readdir dir with
      | Sys_error _ -> [||]
    in
    entries
    |> Array.find_map (fun entry ->
      if entry = "" || entry.[0] = '.' || ignored_dir entry
      then None
      else (
        let path = Filename.concat dir entry in
        if is_symlink path
        then None
        else if has_workspace_file path
        then Some path
        else if Sys.is_directory path
        then go path
        else None))
  in
  match go root with
  | None -> Ok ()
  | Some inner -> Error (Nested_workspace { outer = root; inner })
;;

let resolve_validated ~dir =
  match resolve ~dir with
  | Error _ as e -> e
  | Ok root ->
    (match validate ~root with
     | Ok () -> Ok root
     | Error _ as e -> e)
;;

let enter ~dir =
  match resolve_validated ~dir with
  | Error _ as e -> e
  | Ok root ->
    Sys.chdir root;
    Ok root
;;

type t =
  { root : string
  ; name : string
  }

let enter_cwd () =
  match enter ~dir:(Sys.getcwd ()) with
  | Ok root -> Ok { root; name = workspace_name ~root }
  | Error e -> Error (Sol_cli_exit.failure ("sol: " ^ workspace_error_to_string e))
;;
