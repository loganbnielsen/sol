(* DEC-049: the one owner of Sol-asset resolution. REFAC-114 moved the four
   consumers here; FEAT-101 adds the installed release bundle. *)

type form =
  | Checkout
  | Installed of { version : string }

type t =
  { dir : string
  ; form : form
  }

type error =
  | Invalid_sol_home of string
  | Bundle_version_mismatch of
      { dir : string
      ; bundle : string
      ; binary : string option
      }
  | Missing_bundle of
      { expected : string
      ; version : string
      }
  | Not_found

let fix =
  "  Set SOL_HOME to a Sol checkout or to this release's bundle and re-run:\n\
  \    export SOL_HOME=/path/to/sol"
;;

let error_to_string = function
  | Invalid_sol_home dir ->
    Printf.sprintf
      "SOL_HOME=%s is neither a Sol checkout (framework/ocaml/sol-svc/lib/dune and \
       framework/ocaml/kafka-eio-service/lib/dune, outside any _build tree) nor a \
       release bundle (a VERSION file and platform/).\n\
       %s"
      dir
      fix
  | Bundle_version_mismatch { dir; bundle; binary } ->
    Printf.sprintf
      "SOL_HOME=%s is the bundle of release %s, but this sol is %s; a release uses only \
       its own assets.\n\
       %s"
      dir
      bundle
      (match binary with
       | Some v -> "release " ^ v
       | None -> "a development build")
      fix
  | Missing_bundle { expected; version } ->
    Printf.sprintf
      "this is sol release %s, but its assets are not at %s. Reinstall the release \
       archive so bin/sol and share/sol/%s/ sit under one prefix, or set SOL_HOME to \
       that bundle."
      version
      expected
      version
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

(* An installed bundle root: share/sol/<version>/ holding VERSION and platform/. *)
let bundle_version dir =
  let version_file = Filename.concat dir "VERSION" in
  if
    Sys.file_exists version_file
    && Sys.file_exists (Filename.concat dir "platform/shared/components.json")
  then (
    let ic = open_in version_file in
    let v =
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> input_line ic)
    in
    Some (String.trim v))
  else None
;;

let installed_dir ~exe_dir ~version =
  Filename.concat (Filename.dirname exe_dir) (Filename.concat "share/sol" version)
;;

(* DEC-049's order. An explicit SOL_HOME is a checkout, or a bundle of this very
   release; anything else is an error, never a fall-through. A release binary
   then uses its own bundle and nothing else: walking up to a checkout would hand
   it assets that are not its release's. Only a development build discovers a
   checkout. *)
let resolve_from ~sol_home ~exe_dir ~release_version =
  match sol_home with
  | Some dir when dir <> "" ->
    if is_checkout dir
    then Ok { dir; form = Checkout }
    else (
      match bundle_version dir with
      | Some bundle when Some bundle = release_version ->
        Ok { dir; form = Installed { version = bundle } }
      | Some bundle ->
        Error (Bundle_version_mismatch { dir; bundle; binary = release_version })
      | None -> Error (Invalid_sol_home dir))
  | Some _ | None ->
    (match release_version with
     | Some version ->
       let dir = installed_dir ~exe_dir ~version in
       (match bundle_version dir with
        | Some bundle when bundle = version -> Ok { dir; form = Installed { version } }
        | Some _ | None -> Error (Missing_bundle { expected = dir; version }))
     | None ->
       (match find_ancestor is_checkout exe_dir with
        | Some dir -> Ok { dir; form = Checkout }
        | None -> Error Not_found))
;;

let resolve () =
  resolve_from
    ~sol_home:(Sys.getenv_opt "SOL_HOME")
    ~exe_dir:(running_binary_dir ())
    ~release_version:Sol_cli_build_info.release_version
;;

let resolve_or_exit () =
  match resolve () with
  | Ok t -> t
  | Error e ->
    Printf.eprintf "error: %s\n%!" (error_to_string e);
    exit 1
;;

let dir t = t.dir
let form t = t.form

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

type migration_runner =
  | Build_from_source of { context : string }
  | Published of string

(* An installed release names its runner in the bundle, as a digest reference
   the release workflow wrote after publishing the image built beside this
   binary. Only an immutable reference is accepted. *)
let runner_image_file t = Filename.concat t.dir "migration-runner-image"

let is_digest_ref s =
  match String.index_opt s '@' with
  | Some i ->
    let d = String.sub s (i + 1) (String.length s - i - 1) in
    String.length d = 71
    && String.sub d 0 7 = "sha256:"
    && String.for_all
         (function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false)
         (String.sub d 7 64)
  | None -> false
;;

let migration_runner t =
  match t.form with
  | Checkout -> Ok (Build_from_source { context = t.dir })
  | Installed { version } ->
    let path = runner_image_file t in
    if not (Sys.file_exists path)
    then Error (Printf.sprintf "release %s's bundle has no %s" version path)
    else (
      let ic = open_in path in
      let ref_ =
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> input_line ic)
        |> String.trim
      in
      if is_digest_ref ref_
      then Ok (Published ref_)
      else
        Error
          (Printf.sprintf
             "release %s's migration runner %S is not a digest reference \
              (<image>@sha256:<64 hex>)"
             version
             ref_))
;;
