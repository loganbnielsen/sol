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
let custom_manifest_name = ".sol-custom-materialized"

let is_runtime_artifact name =
  name = ".terraform"
  || name = "errored.tfstate"
  || name = "crash.log"
  || name = ".terraform.tfstate.lock.info"
  || name = manifest_name
  || name = custom_manifest_name
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

let custom_tf_root ~provider ~role =
  let role =
    match role with
    | A.Cluster -> Some "cluster"
    | A.Platform -> Some "platform"
    | A.Bootstrap | A.Authorization -> None
  in
  match role, Sol_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
  | Some role, Some workspace_root ->
    Some
      (Filename.concat
         workspace_root
         (Printf.sprintf "sol/terraform/%s/%s" (Sol_cli_provider.to_string provider) role))
  | Some _, None | None, _ -> None
;;

let custom_file rel =
  let name = Filename.basename rel in
  let eligible =
    String.starts_with ~prefix:"modules/" rel
    || (Filename.dirname rel = "."
        && (Filename.check_suffix name ".tf" || Filename.check_suffix name ".tf.json"))
  in
  eligible
  && (not (is_runtime_artifact name))
  && not (Filename.check_suffix name ".tfvars")
;;

let rec custom_module_sources root rel =
  let open Result.Syntax in
  let path = Filename.concat root rel in
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    let* names =
      match Sys.readdir path with
      | names -> Ok (Array.to_list names |> List.sort String.compare)
      | exception Sys_error message -> Error message
    in
    names
    |> Sol_cli_result.map_list (fun name ->
      custom_module_sources root (Filename.concat rel name))
    |> Result.map List.concat
  | { Unix.st_kind = Unix.S_REG; _ } when custom_file rel -> Ok [ rel ]
  | { Unix.st_kind = Unix.S_REG; _ } -> Ok []
  | { Unix.st_kind = Unix.S_LNK; _ } ->
    Error (Printf.sprintf "symbolic links are not supported in custom Terraform: %s" path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "%s: %s" path (Unix.error_message error))
  | _ -> Error (Printf.sprintf "unsupported custom Terraform file type: %s" path)
;;

let custom_sources_result root =
  let open Result.Syntax in
  let module_path = Filename.concat root "modules" in
  let* root_kind =
    match Unix.lstat root with
    | { Unix.st_kind; _ } -> Ok (Some st_kind)
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (error, _, _) ->
      Error (Printf.sprintf "%s: %s" root (Unix.error_message error))
  in
  match root_kind with
  | None -> Ok []
  | Some Unix.S_DIR ->
    let* names =
      match Sys.readdir root with
      | names -> Ok (Array.to_list names |> List.sort String.compare)
      | exception Sys_error message -> Error message
    in
    let* root_tf_files =
      names
      |> List.filter custom_file
      |> Sol_cli_result.map_list (fun name ->
        let path = Filename.concat root name in
        match Unix.lstat path with
        | { Unix.st_kind = Unix.S_REG; _ } -> Ok name
        | { Unix.st_kind = Unix.S_LNK; _ } ->
          Error
            (Printf.sprintf
               "symbolic links are not supported in custom Terraform: %s"
               path)
        | _ -> Error (Printf.sprintf "unsupported custom Terraform file type: %s" path)
        | exception Unix.Unix_error (error, _, _) ->
          Error (Printf.sprintf "%s: %s" path (Unix.error_message error)))
    in
    let* module_sources =
      match Unix.lstat module_path with
      | { Unix.st_kind = Unix.S_DIR; _ } -> custom_module_sources root "modules"
      | { Unix.st_kind = Unix.S_LNK; _ } ->
        Error
          (Printf.sprintf
             "symbolic links are not supported in custom Terraform: %s"
             module_path)
      | { Unix.st_kind = Unix.S_REG; _ } ->
        Error
          (Printf.sprintf
             "custom Terraform modules path is not a directory: %s"
             module_path)
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
      | exception Unix.Unix_error (error, _, _) ->
        Error (Printf.sprintf "%s: %s" module_path (Unix.error_message error))
      | _ ->
        Error (Printf.sprintf "unsupported custom Terraform file type: %s" module_path)
    in
    Ok (root_tf_files @ module_sources)
  | Some _ -> Error (Printf.sprintf "custom Terraform path is not a directory: %s" root)
;;

let materialize_custom_tf ~provider ~role ~chdir =
  let open Result.Syntax in
  let manifest = Filename.concat chdir custom_manifest_name in
  let* previous = read_manifest manifest in
  let* () =
    if
      List.for_all
        (fun path ->
           path <> ""
           && path <> "."
           && Filename.is_relative path
           && (not (List.mem "." (String.split_on_char '/' path)))
           && not (List.mem ".." (String.split_on_char '/' path)))
        previous
    then Ok ()
    else Error (Printf.sprintf "invalid custom Terraform manifest: %s" manifest)
  in
  let custom_root = custom_tf_root ~provider ~role in
  let* sources =
    match custom_root with
    | None -> Ok []
    | Some root -> custom_sources_result root
  in
  let names = sources in
  let collisions =
    List.filter
      (fun name ->
         (not (List.mem name previous)) && Sys.file_exists (Filename.concat chdir name))
      names
  in
  let* () =
    match collisions with
    | [] -> Ok ()
    | _ ->
      Error
        (Printf.sprintf
           "custom Terraform files would overwrite Sol's files in %s: %s"
           chdir
           (String.concat ", " collisions))
  in
  let* _ =
    previous
    |> List.filter (fun name -> not (List.mem name names))
    |> Sol_cli_result.map_list (fun name ->
      Sol_cli_fs.remove_if_present (Filename.concat chdir name))
  in
  let copy source =
    let target = Filename.concat chdir source in
    let* () = Sol_cli_fs.mkdir_p (Filename.dirname target) in
    let* content =
      match Option.map (fun root -> Filename.concat root source) custom_root with
      | None -> Error "custom Terraform root disappeared"
      | Some path -> Sol_cli_fs.read_file path
    in
    Sol_cli_fs.write_atomic ~perm:0o600 target content
  in
  let* _ = Sol_cli_result.map_list copy sources in
  Sol_cli_fs.write_atomic ~perm:0o600 manifest (String.concat "\n" names ^ "\n")
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
    let chdir = chdir ~provider ~role ~backend_config in
    let* () = materialize_custom_tf ~provider ~role ~chdir in
    Ok chdir
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
