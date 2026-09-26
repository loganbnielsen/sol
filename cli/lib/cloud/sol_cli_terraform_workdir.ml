(* DEC-050: Terraform runs in a per-state working directory materialized from the
   immutable platform assets. See the interface for the contract. *)

module A = Sol_cli_platform_assets

let role_name : A.cloud_role -> string = function
  | A.Cluster -> "cluster"
  | A.Platform -> "platform"
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

let source_trees = [ "platform/cloud"; "platform/shared" ]
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

(* Every asset file under [rel] (a directory relative to [root]), skipping
   runtime artifacts a checkout may hold from Terraform runs before DEC-050. *)
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

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let read_lines path =
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> String.split_on_char '\n' s |> List.filter (fun l -> l <> "")
  | exception Sys_error _ -> []
;;

(* Write via a temporary file and rename, so a crash never leaves a torn file.
   Owner-writable whatever the source's mode: a read-only bundle's files are
   0444, and Terraform may rewrite the lock file it finds here. *)
let write_atomic ~perm path contents =
  let tmp = path ^ ".sol-tmp" in
  Out_channel.with_open_gen
    [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
    perm
    tmp
    (fun oc -> Out_channel.output_string oc contents);
  Unix.chmod tmp perm;
  Unix.rename tmp path
;;

let materialize ~assets ~provider ~role ~backend_config =
  let root = dir ~provider ~role ~backend_config in
  let manifest = Filename.concat root manifest_name in
  try
    mkdir_p root;
    let source_root = A.dir assets in
    let sources = List.concat_map (source_files source_root) source_trees in
    if sources = []
    then Error (Printf.sprintf "no Terraform assets under %s" source_root)
    else (
      (* Only files Sol wrote are ever removed: the previous manifest's, when the
         assets no longer have them. *)
      List.iter
        (fun rel ->
           if not (List.mem rel sources)
           then (
             try Sys.remove (Filename.concat root rel) with
             | Sys_error _ -> ()))
        (read_lines manifest);
      List.iter
        (fun rel ->
           let src = Filename.concat source_root rel in
           let dst = Filename.concat root rel in
           mkdir_p (Filename.dirname dst);
           let perm = (Unix.stat src).Unix.st_perm lor 0o600 in
           write_atomic ~perm dst (In_channel.with_open_bin src In_channel.input_all))
        sources;
      write_atomic ~perm:0o644 manifest (String.concat "\n" sources ^ "\n");
      Ok (chdir ~provider ~role ~backend_config))
  with
  | Sys_error msg | Failure msg ->
    Error (Printf.sprintf "cannot prepare Terraform's working directory %s: %s" root msg)
  | Unix.Unix_error (e, fn, arg) ->
    Error
      (Printf.sprintf
         "cannot prepare Terraform's working directory %s: %s %s: %s"
         root
         fn
         arg
         (Unix.error_message e))
;;
