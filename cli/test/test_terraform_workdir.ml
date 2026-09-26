(* DEC-050: Terraform runs in a per-state working directory materialized from the
   immutable platform assets. The data home is isolated by cli/test/dune (INFRA-075). *)

module A = Sol_cli_platform_assets
module W = Sol_cli_terraform_workdir

let write path text =
  ignore
    (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote (Filename.dirname path))));
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc text)
;;

let read path = In_channel.with_open_bin path In_channel.input_all

let with_tmpdir f =
  let dir = Filename.temp_file "sol-workdir-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Sys.command
           (Printf.sprintf
              "chmod -R u+w %s; rm -rf %s"
              (Filename.quote dir)
              (Filename.quote dir))))
    (fun () -> f (Unix.realpath dir))
;;

(* A checkout-shaped asset root with one provider's roots and the shared tree. *)
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
  | Error e -> Alcotest.fail (A.error_to_string e)
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
  | Error msg -> Alcotest.fail msg
;;

let dir_of ?(provider = Sol_cli_provider.Aws) ?(role = A.Cluster) backend_config =
  W.dir ~provider ~role ~backend_config
;;

let test_identity () =
  let a = dir_of (backend "prod/aws/us-east-1") in
  Alcotest.(check bool)
    "two targets never share"
    true
    (a <> dir_of (backend "dev/aws/us-east-1"));
  Alcotest.(check bool)
    "cluster and platform never share"
    true
    (a <> dir_of ~role:A.Platform (backend "prod/aws/us-east-1"));
  Alcotest.(check bool)
    "providers never share"
    true
    (a <> dir_of ~provider:Sol_cli_provider.Gcp (backend "prod/aws/us-east-1"));
  Alcotest.(check string)
    "the backend's order does not change the identity"
    a
    (dir_of (List.rev (backend "prod/aws/us-east-1")));
  Alcotest.(check bool)
    "absolute, under Sol's state"
    true
    ((not (Filename.is_relative a))
     && String.ends_with ~suffix:"sol/terraform" (Filename.dirname a))
;;

let test_materializes_the_assets () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    let chdir = materialize assets () in
    Alcotest.(check string)
      "chdir is the root's copy"
      (Filename.concat
         (W.dir
            ~provider:Sol_cli_provider.Aws
            ~role:A.Cluster
            ~backend_config:(backend "prod/aws/us-east-1"))
         "platform/cloud/aws/cluster")
      chdir;
    Alcotest.(check string)
      "root"
      "# cluster v1\n"
      (read (Filename.concat chdir "main.tf"));
    Alcotest.(check string)
      "the shared module, at its relative path"
      "# module\n"
      (read (Filename.concat chdir "../../modules/platform/main.tf"));
    Alcotest.(check string)
      "the shared tree the module reads"
      "{}\n"
      (read (Filename.concat chdir "../../../shared/components.json")))
;;

let test_runtime_artifacts_in_the_source_are_not_copied () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    write (Filename.concat root "platform/cloud/aws/cluster/.terraform/providers/x") "p";
    write (Filename.concat root "platform/cloud/aws/cluster/errored.tfstate") "old";
    let chdir = materialize assets ~target:"artifacts/aws/us-east-1" () in
    Alcotest.(check bool)
      "no .terraform copied"
      false
      (Sys.file_exists (Filename.concat chdir ".terraform/providers/x"));
    Alcotest.(check bool)
      "no errored.tfstate copied"
      false
      (Sys.file_exists (Filename.concat chdir "errored.tfstate")))
;;

let test_rematerialize_is_authoritative_and_preserves () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    let chdir = materialize assets ~target:"recover/aws/us-east-1" () in
    (* What Terraform and the operator leave behind. *)
    write (Filename.concat chdir "errored.tfstate") "the only record";
    write (Filename.concat chdir ".terraform/fake") "plugins";
    write (Filename.concat chdir "notes.txt") "mine";
    (* The assets change: one file edited, one added, one removed. *)
    write (Filename.concat root "platform/cloud/aws/cluster/main.tf") "# cluster v2\n";
    write (Filename.concat root "platform/cloud/aws/cluster/added.tf") "# new\n";
    let chdir' = materialize assets ~target:"recover/aws/us-east-1" () in
    Alcotest.(check string) "same working directory" chdir chdir';
    Alcotest.(check string)
      "edited source follows the assets"
      "# cluster v2\n"
      (read (Filename.concat chdir "main.tf"));
    Alcotest.(check string)
      "added source appears"
      "# new\n"
      (read (Filename.concat chdir "added.tf"));
    Sys.remove (Filename.concat root "platform/cloud/aws/cluster/added.tf");
    ignore (materialize assets ~target:"recover/aws/us-east-1" ());
    Alcotest.(check bool)
      "a source the assets dropped is removed"
      false
      (Sys.file_exists (Filename.concat chdir "added.tf"));
    Alcotest.(check string)
      "errored.tfstate is never touched"
      "the only record"
      (read (Filename.concat chdir "errored.tfstate"));
    Alcotest.(check string)
      ".terraform is kept"
      "plugins"
      (read (Filename.concat chdir ".terraform/fake"));
    Alcotest.(check string)
      "a file Sol did not write is kept"
      "mine"
      (read (Filename.concat chdir "notes.txt")))
;;

(* A read-only bundle's files are 0444, in 0555 directories. *)
let test_read_only_assets () =
  with_tmpdir (fun root ->
    let assets = fake_assets root in
    ignore
      (Sys.command
         (Printf.sprintf
            "chmod -R a-w %s"
            (Filename.quote (Filename.concat root "platform"))));
    let chdir = materialize assets ~target:"readonly/aws/us-east-1" () in
    let perm = (Unix.stat (Filename.concat chdir "main.tf")).Unix.st_perm in
    Alcotest.(check bool) "the copy is owner-writable" true (perm land 0o200 <> 0);
    (* and a second run can rewrite it *)
    ignore (materialize assets ~target:"readonly/aws/us-east-1" ());
    Alcotest.(check bool)
      "the assets stayed read-only"
      true
      ((Unix.stat (Filename.concat root "platform/cloud/aws/cluster/main.tf"))
         .Unix.st_perm
       land 0o222
       = 0))
;;

let () =
  Alcotest.run
    "terraform_workdir"
    [ ( "workdir"
      , [ Alcotest.test_case "identity isolates states" `Quick test_identity
        ; Alcotest.test_case "materializes the assets" `Quick test_materializes_the_assets
        ; Alcotest.test_case
            "runtime artifacts are not copied"
            `Quick
            test_runtime_artifacts_in_the_source_are_not_copied
        ; Alcotest.test_case
            "re-materialization is authoritative and preserves"
            `Quick
            test_rematerialize_is_authoritative_and_preserves
        ; Alcotest.test_case "read-only assets" `Quick test_read_only_assets
        ] )
    ]
;;
