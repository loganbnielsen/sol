let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let contains haystack needle = Sol_cli_string.contains ~needle haystack

let assert_contains label haystack needle =
  check_bool
    (Printf.sprintf "%s: contains %S" label needle)
    true
    (contains haystack needle)
;;

let read_file path =
  let ic = open_in path in
  let s = In_channel.input_all ic in
  close_in ic;
  s
;;

let write_file path content =
  Result.get_ok (Sol_cli_fs.mkdir_p (Filename.dirname path));
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let in_temp_dir f =
  let orig = Sys.getcwd () in
  let dir = Filename.temp_file "sol-ci-init-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir orig) f
;;

let seed_workspace () = write_file "sol.yml" "project: testapp\n"
let init ~force () = Sol_cli_ci.init_github ~force ~cwd:(Sys.getcwd ())

let test_writes_an_oidc_workflow () =
  in_temp_dir (fun () ->
    seed_workspace ();
    match init ~force:false () with
    | Error message -> Windtrap.fail message
    | Ok outcome ->
      check_bool "written" true outcome.written;
      check_bool
        "landed at the conventional path"
        true
        (Sys.file_exists Sol_cli_ci.target_rel);
      let content = read_file Sol_cli_ci.target_rel in
      assert_contains "OIDC id-token permission" content "id-token: write";
      assert_contains "AWS OIDC assumption" content "role-to-assume";
      assert_contains "GCP Workload Identity" content "workload_identity_provider";
      assert_contains "explicit target" content {|deploy "$SOL_TARGET"|};
      assert_contains "migrate runs the same lifecycle" content {|migrate "$SOL_TARGET"|};
      check_bool "no kubeconfig credential" false (contains content "KUBECONFIG"))
;;

let test_rerun_is_idempotent () =
  in_temp_dir (fun () ->
    seed_workspace ();
    let first = init ~force:false () |> Result.get_ok in
    check_bool "first run writes" true first.written;
    let before = read_file Sol_cli_ci.target_rel in
    let second = init ~force:false () |> Result.get_ok in
    check_bool "second run is a no-op" false second.written;
    check_bool
      "content unchanged"
      true
      (String.equal before (read_file Sol_cli_ci.target_rel)))
;;

let test_refuses_to_clobber_an_edited_workflow () =
  in_temp_dir (fun () ->
    seed_workspace ();
    write_file Sol_cli_ci.target_rel "# hand-edited\n";
    match init ~force:false () with
    | Ok _ -> Windtrap.fail "a differing workflow was overwritten without --force"
    | Error message ->
      assert_contains "the refusal names the file" message Sol_cli_ci.target_rel;
      check_bool
        "the edited file is untouched"
        true
        (String.equal "# hand-edited\n" (read_file Sol_cli_ci.target_rel)))
;;

let test_force_overwrites () =
  in_temp_dir (fun () ->
    seed_workspace ();
    write_file Sol_cli_ci.target_rel "# hand-edited\n";
    match init ~force:true () with
    | Error message -> Windtrap.fail message
    | Ok outcome ->
      check_bool "written" true outcome.written;
      assert_contains
        "regenerated as the supported workflow"
        (read_file Sol_cli_ci.target_rel)
        "id-token: write")
;;

let%test "ci init: writes an OIDC workflow into an existing workspace" =
  test_writes_an_oidc_workflow ()
;;

let%test "ci init: a re-run is idempotent" = test_rerun_is_idempotent ()

let%test "ci init: refuses to clobber an edited workflow" =
  test_refuses_to_clobber_an_edited_workflow ()
;;

let%test "ci init: --force overwrites" = test_force_overwrites ()
