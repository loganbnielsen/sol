module A = Sol_cli_platform_assets

let role_name : A.cloud_role -> string = function
  | A.Bootstrap -> "bootstrap"
  | A.Cluster -> "cluster"
  | A.Platform -> "platform"
  | A.Authorization -> "authorization"
;;

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
;;

let dir ~provider ~role ~backend_config =
  let pname = Sol_cli_provider.to_string provider in
  let digest =
    Digest.to_hex
      (Digest.string
         (String.concat
            "\x00"
            (pname :: role_name role :: List.sort String.compare backend_config)))
  in
  Filename.concat
    (absolute (Filename.concat Sol_cli_state.dir "terraform"))
    (Printf.sprintf "%s-%s-%s" pname (role_name role) (String.sub digest 0 16))
;;

let chdir ~provider ~role ~backend_config =
  Filename.concat (dir ~provider ~role ~backend_config) (A.cloud_root_rel provider role)
;;

let source_trees = A.terraform_trees
let manifest_name = ".sol-materialized"

let is_runtime_artifact name =
  name = ".terraform"
  || name = "errored.tfstate"
  || name = "crash.log"
  || name = ".terraform.tfstate.lock.info"
  || name = manifest_name
  || String.starts_with ~prefix:"terraform.tfstate" name
  || Filename.check_suffix name ".tfstate"
  || Filename.check_suffix name ".tfstate.backup"
;;

let rec source_files root rel =
  let path = Filename.concat root rel in
  if Sys.is_directory path
  then
    Sys.readdir path
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter (fun name -> not (is_runtime_artifact name))
    |> List.concat_map (fun name -> source_files root (Filename.concat rel name))
  else [ rel ]
;;

(* The source list Sol wrote on the previous materialization. Only confirmed
   initial absence is empty: a manifest that exists but cannot be read is
   unobservable, so materialization must refuse rather than treat it as a first
   run, which would leave stale copied sources active and lose the cleanup
   history. *)
let read_manifest path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | exception Unix.Unix_error (e, _, _) ->
    Error (Printf.sprintf "%s: %s" path (Unix.error_message e))
  | { Unix.st_kind = Unix.S_REG; _ } ->
    (match Sol_cli_fs.read_file path with
     | Ok content ->
       Ok (String.split_on_char '\n' content |> List.filter (fun l -> l <> ""))
     | Error message -> Error message)
  | _ -> Error (Printf.sprintf "%s is not a readable regular file" path)
;;

let materialize ~assets ~provider ~role ~backend_config =
  let open Result.Syntax in
  let root = dir ~provider ~role ~backend_config in
  let manifest = Filename.concat root manifest_name in
  let source_root = A.dir assets in
  let read path =
    match In_channel.with_open_bin path In_channel.input_all with
    | content -> Ok content
    | exception Sys_error message -> Error message
  in
  let copy rel =
    let src = Filename.concat source_root rel in
    let dst = Filename.concat root rel in
    let* () = Sol_cli_fs.mkdir_p (Filename.dirname dst) in
    let* perm =
      match Unix.stat src with
      | { Unix.st_perm; _ } -> Ok (st_perm lor 0o600)
      | exception Unix.Unix_error (e, _, _) ->
        Error (Printf.sprintf "%s: %s" src (Unix.error_message e))
    in
    let* content = read src in
    Sol_cli_fs.write_atomic ~perm dst content
  in
  let prepare sources =
    let* () = Sol_cli_fs.mkdir_p root in
    let* previous = read_manifest manifest in
    let* _ =
      previous
      |> List.filter (fun rel -> not (List.mem rel sources))
      |> Sol_cli_result.map_list (fun rel ->
        Sol_cli_fs.remove_if_present (Filename.concat root rel))
    in
    let* _ = Sol_cli_result.map_list copy sources in
    let* () =
      Sol_cli_fs.write_atomic ~perm:0o644 manifest (String.concat "\n" sources ^ "\n")
    in
    Ok (chdir ~provider ~role ~backend_config)
  in
  match List.concat_map (source_files source_root) source_trees with
  | exception Sys_error message ->
    Error
      (Printf.sprintf "cannot read the Terraform assets under %s: %s" source_root message)
  | [] -> Error (Printf.sprintf "no Terraform assets under %s" source_root)
  | sources ->
    prepare sources
    |> Result.map_error
         (Printf.sprintf "cannot prepare Terraform's working directory %s: %s" root)
;;
