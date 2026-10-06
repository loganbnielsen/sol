module A = Sol_cli_platform_assets
module W = Sol_cli_terraform_workdir

let write path text =
  Result.get_ok (Sol_cli_fs.mkdir_p (Filename.dirname path));
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc text)
;;

let read path = In_channel.with_open_bin path In_channel.input_all

let rec chmod_tree f path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; st_perm; _ } ->
    let after = f st_perm in
    if after land 0o200 <> 0 then Unix.chmod path after;
    Sys.readdir path |> Array.iter (fun e -> chmod_tree f (Filename.concat path e));
    if after land 0o200 = 0 then Unix.chmod path after
  | { Unix.st_kind = Unix.S_REG; st_perm; _ } -> Unix.chmod path (f st_perm)
  | _ -> ()
;;

let with_tmpdir f =
  let dir = Filename.temp_file "sol-workdir-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      chmod_tree (fun perm -> perm lor 0o200) dir;
      ignore (Sol_cli_fs.remove_tree dir))
    (fun () -> f (Unix.realpath dir))
;;

let fake_assets root =
  write (Filename.concat root "framework/ocaml/sol-svc/lib/dune") "";
  write (Filename.concat root "framework/ocaml/kafka-eio-service/lib/dune") "";
  write (Filename.concat root "platform/cloud/aws/cluster/main.tf") "# cluster v1\n";
  write (Filename.concat root "platform/cloud/aws/platform/main.tf") "# platform\n";
  write (Filename.concat root "platform/cloud/modules/platform/main.tf") "# module\n";
  write (Filename.concat root "platform/shared/components.json") "{}\n";
  match
    A.resolve_from ~sol_home:(Some root) ~exe_dir:"/nonexistent" ~release_version:None
  with
  | Ok t -> t
  | Error e -> Windtrap.fail (A.error_to_string e)
;;

let backend target = [ "bucket=b"; Printf.sprintf "key=sol/cloud/%s.tfstate" target ]

let materialize assets ?(role = A.Cluster) ?(target = "prod/aws/us-east-1") () =
  match
    W.materialize
      ~assets
      ~provider:Sol_cli_provider.Aws
      ~role
      ~backend_config:(backend target)
  with
  | Ok chdir -> chdir
  | Error msg -> Windtrap.fail msg
;;

let dir_of ?(provider = Sol_cli_provider.Aws) ?(role = A.Cluster) backend_config =
  W.dir ~provider ~role ~backend_config
;;

let test_identity () =
  let a = dir_of (backend "prod/aws/us-east-1") in
  Windtrap.equal
    Windtrap.bool
    ~msg:"two targets never share"
    true
    (a <> dir_of (backend "dev/aws/us-east-1"));
  Windtrap.equal
    Windtrap.bool
    ~msg:"cluster and platform never share"
    true
    (a <> dir_of ~role:A.Platform (backend "prod/aws/us-east-1"));
  Windtrap.equal
    Windtrap.bool
    ~msg:"providers never share"
    true
    (a <> dir_of ~provider:Sol_cli_provider.Gcp (backend "prod/aws/us-east-1"));
  Windtrap.equal
    Windtrap.string
    ~msg:"the backend's order does not change the identity"
    a
    (dir_of (List.rev (backend "prod/aws/us-east-1")));
  Windtrap.equal
    Windtrap.bool
    ~msg:"absolute, under Sol's state"
    true
    ((not (Filename.is_relative a))
     && String.ends_with ~suffix:"sol/terraform" (Filename.dirname a))
;;

let test_materializes_the_assets () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    let chdir = materialize assets () in
    Windtrap.equal
      Windtrap.string
      ~msg:"chdir is the root's copy"
      (Filename.concat
         (W.dir
            ~provider:Sol_cli_provider.Aws
            ~role:A.Cluster
            ~backend_config:(backend "prod/aws/us-east-1"))
         "platform/cloud/aws/cluster")
      chdir;
    Windtrap.equal
      Windtrap.string
      ~msg:"root"
      "# cluster v1\n"
      (read (Filename.concat chdir "main.tf"));
    Windtrap.equal
      Windtrap.string
      ~msg:"the shared module, at its relative path"
      "# module\n"
      (read (Filename.concat chdir "../../modules/platform/main.tf"));
    Windtrap.equal
      Windtrap.string
      ~msg:"the shared tree the module reads"
      "{}\n"
      (read (Filename.concat chdir "../../../shared/components.json")))
;;

let test_runtime_artifacts_in_the_source_are_not_copied () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    write (Filename.concat root "platform/cloud/aws/cluster/.terraform/providers/x") "p";
    write (Filename.concat root "platform/cloud/aws/cluster/errored.tfstate") "old";
    let chdir = materialize assets ~target:"artifacts/aws/us-east-1" () in
    Windtrap.equal
      Windtrap.bool
      ~msg:"no .terraform copied"
      false
      (Sys.file_exists (Filename.concat chdir ".terraform/providers/x"));
    Windtrap.equal
      Windtrap.bool
      ~msg:"no errored.tfstate copied"
      false
      (Sys.file_exists (Filename.concat chdir "errored.tfstate")))
;;

let test_rematerialize_is_authoritative_and_preserves () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    let chdir = materialize assets ~target:"recover/aws/us-east-1" () in
    write (Filename.concat chdir "errored.tfstate") "the only record";
    write (Filename.concat chdir ".terraform/fake") "plugins";
    write (Filename.concat chdir "notes.txt") "mine";
    write (Filename.concat root "platform/cloud/aws/cluster/main.tf") "# cluster v2\n";
    write (Filename.concat root "platform/cloud/aws/cluster/added.tf") "# new\n";
    let chdir' = materialize assets ~target:"recover/aws/us-east-1" () in
    Windtrap.equal Windtrap.string ~msg:"same working directory" chdir chdir';
    Windtrap.equal
      Windtrap.string
      ~msg:"edited source follows the assets"
      "# cluster v2\n"
      (read (Filename.concat chdir "main.tf"));
    Windtrap.equal
      Windtrap.string
      ~msg:"added source appears"
      "# new\n"
      (read (Filename.concat chdir "added.tf"));
    Sys.remove (Filename.concat root "platform/cloud/aws/cluster/added.tf");
    ignore (materialize assets ~target:"recover/aws/us-east-1" ());
    Windtrap.equal
      Windtrap.bool
      ~msg:"a source the assets dropped is removed"
      false
      (Sys.file_exists (Filename.concat chdir "added.tf"));
    Windtrap.equal
      Windtrap.string
      ~msg:"errored.tfstate is never touched"
      "the only record"
      (read (Filename.concat chdir "errored.tfstate"));
    Windtrap.equal
      Windtrap.string
      ~msg:".terraform is kept"
      "plugins"
      (read (Filename.concat chdir ".terraform/fake"));
    Windtrap.equal
      Windtrap.string
      ~msg:"a file Sol did not write is kept"
      "mine"
      (read (Filename.concat chdir "notes.txt")))
;;

let test_read_only_assets () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    chmod_tree (fun perm -> perm land lnot 0o222) (Filename.concat root "platform");
    let chdir = materialize assets ~target:"readonly/aws/us-east-1" () in
    let perm = (Unix.stat (Filename.concat chdir "main.tf")).Unix.st_perm in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the copy is owner-writable"
      true
      (perm land 0o200 <> 0);
    ignore (materialize assets ~target:"readonly/aws/us-east-1" ());
    Windtrap.equal
      Windtrap.bool
      ~msg:"the assets stayed read-only"
      true
      ((Unix.stat (Filename.concat root "platform/cloud/aws/cluster/main.tf"))
         .Unix.st_perm
       land 0o222
       = 0))
;;

let test_unreadable_manifest_refuses () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    let target = "unreadable/aws/us-east-1" in
    let chdir = materialize assets ~target () in
    write (Filename.concat root "platform/cloud/aws/cluster/added.tf") "# new\n";
    ignore (materialize assets ~target ());
    Windtrap.equal
      Windtrap.bool
      ~msg:"the added source was copied"
      true
      (Sys.file_exists (Filename.concat chdir "added.tf"));
    Sys.remove (Filename.concat root "platform/cloud/aws/cluster/added.tf");
    let manifest =
      Filename.concat
        (W.dir
           ~provider:Sol_cli_provider.Aws
           ~role:A.Cluster
           ~backend_config:(backend target))
        W.manifest_name
    in
    Sys.remove manifest;
    Unix.mkdir manifest 0o755;
    (match
       W.materialize
         ~assets
         ~provider:Sol_cli_provider.Aws
         ~role:A.Cluster
         ~backend_config:(backend target)
     with
     | Ok _ -> Windtrap.fail "an unobservable manifest was accepted as a first run"
     | Error message ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"the refusal names the manifest"
         true
         (Sol_cli_string.contains ~needle:W.manifest_name message));
    Windtrap.equal
      Windtrap.bool
      ~msg:"a source the manifest tracked is not removed on a failed read"
      true
      (Sys.file_exists (Filename.concat chdir "added.tf"));
    Windtrap.equal
      Windtrap.string
      ~msg:"the copied asset is unchanged"
      "# cluster v1\n"
      (read (Filename.concat chdir "main.tf"));
    Windtrap.equal
      Windtrap.bool
      ~msg:"the unobservable manifest is left in place"
      true
      (Sys.file_exists manifest))
;;

let%test "workdir: identity isolates states" = test_identity ()
let%test "workdir: materializes the assets" = test_materializes_the_assets ()

let%test "workdir: runtime artifacts are not copied" =
  test_runtime_artifacts_in_the_source_are_not_copied ()
;;

let%test "workdir: re-materialization is authoritative and preserves" =
  test_rematerialize_is_authoritative_and_preserves ()
;;

let%test "workdir: read-only assets" = test_read_only_assets ()

let%test
    "workdir: an unobservable manifest refuses without changing the working directory"
  =
  test_unreadable_manifest_refuses ()
;;
