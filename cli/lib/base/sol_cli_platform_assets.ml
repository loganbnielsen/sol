(* DEC-049: the one owner of Sol-asset resolution. REFAC-114 moves the four
   consumers here with source-checkout behaviour unchanged. *)

type t = { dir : string }

type error =
  | Invalid_sol_home of string
  | Not_found

let fix =
  "  Set SOL_HOME to your Sol checkout and re-run:\n    export SOL_HOME=/path/to/sol"
;;

let error_to_string = function
  | Invalid_sol_home dir ->
    Printf.sprintf
      "SOL_HOME=%s is not a Sol checkout (it has no framework/ocaml/sol-svc/lib/dune and \
       framework/ocaml/kafka-eio-service/lib/dune, or it is inside a _build tree).\n\
       %s"
      dir
      fix
  | Not_found ->
    Printf.sprintf
      "cannot locate Sol's platform assets: no Sol checkout above this binary.\n%s"
      fix
;;

(* A dune build context mirrors source directories under `_build/...`,
   including the two framework sentinels. Never accept one, or CLI tests run
   from `_build/default/cli/test` would resolve to the build tree. *)
let inside_build_context dir = String.split_on_char '/' dir |> List.mem "_build"

let is_checkout dir =
  (not (inside_build_context dir))
  && Sys.file_exists (Filename.concat dir "framework/ocaml/sol-svc/lib/dune")
  && Sys.file_exists (Filename.concat dir "framework/ocaml/kafka-eio-service/lib/dune")
;;

let rec realpath path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
  in
  try
    let target = Unix.readlink path in
    let target =
      if Filename.is_relative target
      then Filename.concat (Filename.dirname path) target
      else target
    in
    realpath target
  with
  | Unix.Unix_error ((Unix.EINVAL | Unix.ENOENT), _, _) -> path
;;

let rec find_ancestor pred dir =
  if pred dir
  then Some dir
  else (
    let parent = Filename.dirname dir in
    if parent = dir then None else find_ancestor pred parent)
;;

let running_binary_dir () =
  let exe =
    try Unix.readlink "/proc/self/exe" with
    | Unix.Unix_error _ -> Sys.executable_name
  in
  Filename.dirname (realpath exe)
;;

let resolve () =
  match Sys.getenv_opt "SOL_HOME" with
  | Some dir when dir <> "" ->
    if is_checkout dir then Ok { dir } else Error (Invalid_sol_home dir)
  | Some _ | None ->
    (match find_ancestor is_checkout (running_binary_dir ()) with
     | Some dir -> Ok { dir }
     | None -> Error Not_found)
;;

let resolve_or_exit () =
  match resolve () with
  | Ok t -> t
  | Error e ->
    Printf.eprintf "error: %s\n%!" (error_to_string e);
    exit 1
;;

let dir t = t.dir

type cloud_role =
  | Cluster
  | Platform

let cloud_root_rel provider role =
  Printf.sprintf
    "platform/cloud/%s/%s"
    (Sol_cli_provider.to_string provider)
    (match role with
     | Cluster -> "cluster"
     | Platform -> "platform")
;;

let under t rel = Filename.concat t.dir rel
let cloud_root t provider role = under t (cloud_root_rel provider role)
let components_json t = under t "platform/shared/components.json"

let dashboard t name =
  under t (Filename.concat "platform/shared/observability/dashboards" name)
;;

let alloy_template t = under t "platform/shared/observability/alloy/logs.alloy.tftpl"

type migration_runner = Build_from_source of { context : string }

let migration_runner t = Build_from_source { context = t.dir }
