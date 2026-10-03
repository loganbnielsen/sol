let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path)

let with_tmp f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("sol-check-" ^ string_of_int (Random.bits ()))
  in
  mkdir_p root;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       let cwd = Sys.getcwd () in
       Fun.protect
         ~finally:(fun () -> Sys.chdir cwd)
         (fun () ->
            Sys.chdir root;
            write "sol.yml" "";
            f root))
;;

let has_msg needle findings =
  findings
  |> List.exists (fun (f : Sol_cli_check.finding) ->
    Sol_cli_string.contains ~needle f.message)
;;

let facts () =
  match Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) with
  | Ok facts -> facts
  | Error e -> Windtrap.fail ("workspace model failed to load: " ^ e)
;;

let test_missing_app_result () =
  with_tmp (fun _ ->
    match Sol_cli_manifest.discover_services () with
    | Error Sol_cli_manifest.Missing_app_dir -> ()
    | Error (Sol_cli_manifest.Workspace_error _) ->
      Windtrap.fail "expected Missing_app_dir, got a workspace error"
    | Ok _ -> Windtrap.fail "expected missing app error")
;;

let test_not_in_workspace_result () =
  with_tmp (fun _ ->
    Sys.remove "sol.yml";
    match Sol_cli_manifest.discover_services () with
    | Error (Sol_cli_manifest.Workspace_error Sol_cli_workspace.Not_in_workspace) -> ()
    | Error e ->
      Windtrap.fail
        ("expected not-in-workspace, got: " ^ Sol_cli_manifest.discover_error_to_string e)
    | Ok _ -> Windtrap.fail "expected discovery to fail outside a workspace")
;;

let test_discover_valid_service () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    match Sol_cli_manifest.discover_services () with
    | Error e -> Windtrap.fail (Sol_cli_manifest.discover_error_to_string e)
    | Ok [ svc ] ->
      Windtrap.equal Windtrap.string ~msg:"domain" "payments" svc.domain;
      Windtrap.equal Windtrap.string ~msg:"name" "charge_svc" svc.name
    | Ok _ -> Windtrap.fail "expected one service")
;;

let test_typed_scan_reports_missing_dockerfile_and_unexpected_dirs () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    mkdir_p "app/payments/helpers";
    match Sol_cli_manifest.scan_workspace () with
    | Error e -> Windtrap.fail (Sol_cli_manifest.discover_error_to_string e)
    | Ok scan ->
      Windtrap.equal Windtrap.int ~msg:"workload count" 1 (List.length scan.workloads);
      let _, has_dockerfile = List.hd scan.workloads in
      Windtrap.equal Windtrap.bool ~msg:"has dockerfile false" false has_dockerfile;
      Windtrap.equal Windtrap.int ~msg:"unexpected count" 1 (List.length scan.unexpected);
      let _, unexpected_name, _ = List.hd scan.unexpected in
      Windtrap.equal Windtrap.string ~msg:"unexpected name" "helpers" unexpected_name)
;;

let test_check_valid_service () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"DATABASE_URL\"]\n";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"no errors"
      false
      (Sol_cli_check.has_errors findings))
;;

let test_check_bad_secret_key () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"bad-key\"]\n";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"has errors"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"mentions invalid secret"
      true
      (has_msg "invalid runtime secret key" findings))
;;

let test_check_bad_build_secret_key () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write
      "app/payments/charge_svc/sol.toml"
      "[infra.env]\nbuild_secrets = [\"bad-key\"]\n";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"has errors"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the build-time scope"
      true
      (has_msg "invalid build-time secret key" findings))
;;

let test_check_missing_dockerfile () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"has errors"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"mentions Dockerfile"
      true
      (has_msg "Dockerfile is missing" findings))
;;

let test_run_services_scopes_the_check () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"DATABASE_URL\"]\n";
    mkdir_p "app/comms/notify_worker";
    write "app/comms/notify_worker/Dockerfile" "FROM scratch\n";
    write "app/comms/notify_worker/sol.toml" "[infra.env]\nsecrets = [\"bad-key\"]\n";
    let services = Result.get_ok (Sol_cli_manifest.discover_services ()) in
    let charge =
      List.filter (fun (s : Sol_cli_manifest.service) -> s.name = "charge_svc") services
    in
    let findings = Sol_cli_check.run_services ~facts:(facts ()) charge in
    Windtrap.equal
      Windtrap.bool
      ~msg:"only the selected workload is checked"
      false
      (Sol_cli_check.has_errors findings))
;;

let test_undeclared_workload_warns () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"warns that the workload declares no language"
      true
      (has_msg "declares no language" findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"a warning, not an error"
      false
      (Sol_cli_check.has_errors findings))
;;

let test_declared_workload_does_not_warn () =
  with_tmp (fun _ ->
    write "sol.yml" "services:\n  charge_svc:\n    language: ocaml\n";
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"no declaration warning"
      false
      (has_msg "declares no language" findings))
;;

let run_sol ~root args =
  let stdout_path = Filename.concat root "stdout" in
  let stderr_path = Filename.concat root "stderr" in
  let command =
    String.concat " " (List.map Filename.quote (Cli_binary.path () :: args))
    ^ " > "
    ^ Filename.quote stdout_path
    ^ " 2> "
    ^ Filename.quote stderr_path
  in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  match
    Sol_cli_process.run
      ~echo:false
      (Sol_cli_process.cmd ~cwd:root [ "sh"; "-c"; command ])
  with
  | Ok _ -> 0, read stdout_path, read stderr_path
  | Error (Non_zero failure) -> failure.exit_code, read stdout_path, read stderr_path
  | Error error -> Windtrap.fail (Sol_cli_process.error_to_string error)
;;

let with_subprocess_workspace f =
  let root = Filename.temp_dir "sol-check-exit-" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       Result.get_ok
         (Sol_cli_fs.write_atomic
            (Filename.concat root "sol.yml")
            "services:\n  charge_svc:\n    language: ocaml\n");
       f root)
;;

let test_failed_check_exits_two () =
  with_subprocess_workspace (fun root ->
    let unit = Filename.concat root "app/payments/charge_svc" in
    ignore (Sol_cli_fs.mkdir_p unit);
    ignore (Sol_cli_fs.write_atomic (Filename.concat unit "sol.toml") "");
    let code, _stdout, stderr = run_sol ~root [ "check" ] in
    Windtrap.equal Windtrap.int ~msg:"a failed check exits 2" 2 code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"and still names the failure"
      true
      (Sol_cli_string.contains ~needle:"Dockerfile is missing" stderr))
;;

let test_unreadable_workspace_exits_one () =
  with_subprocess_workspace (fun root ->
    let path = Filename.concat root "sol.yml" in
    let denied =
      if Unix.geteuid () = 0
      then (
        Sys.remove path;
        Unix.mkdir path 0o755;
        false)
      else (
        Unix.chmod path 0o000;
        true)
    in
    let code, _stdout, stderr = run_sol ~root [ "check" ] in
    Windtrap.equal
      Windtrap.int
      ~msg:"an unreadable workspace exits 1, not an internal error"
      1
      code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"never prints an uncaught exception"
      false
      (Sol_cli_string.contains ~needle:"uncaught exception" stderr);
    if denied
    then
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the file whose read was denied"
        true
        (Sol_cli_string.contains ~needle:"sol.yml" stderr))
;;

let test_unreadable_config_is_an_error () =
  with_tmp (fun _ ->
    Sys.remove "sol.yml";
    Unix.mkdir "sol.yml" 0o755;
    match Sol_cli_config.sol_yml_services ~root:(Sys.getcwd ()) with
    | Ok _ -> Windtrap.fail "expected an error for a sol.yml that cannot be read"
    | Error e ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the unreadable file"
        true
        (Sol_cli_string.contains ~needle:"sol.yml" (Sol_cli_config.error_to_string e)))
;;

let%test "discover: missing app returns error" = test_missing_app_result ()
let%test "discover: outside a workspace returns error" = test_not_in_workspace_result ()
let%test "discover: valid service" = test_discover_valid_service ()

let%test "discover: typed scan facts" =
  test_typed_scan_reports_missing_dockerfile_and_unexpected_dirs ()
;;

let%test "check: valid service" = test_check_valid_service ()
let%test "check: bad secret key" = test_check_bad_secret_key ()
let%test "check: bad build secret key" = test_check_bad_build_secret_key ()
let%test "check: missing Dockerfile" = test_check_missing_dockerfile ()

let%test "check: run_services checks only the selected set" =
  test_run_services_scopes_the_check ()
;;

let%test "check: an undeclared workload warns" = test_undeclared_workload_warns ()

let%test "check: a declared workload does not warn" =
  test_declared_workload_does_not_warn ()
;;

let%test "check: a failed check exits 2" = test_failed_check_exits_two ()
let%test "check: an unreadable workspace exits 1" = test_unreadable_workspace_exits_one ()

let%test "check: an unreadable sol.yml is an error, not an exception" =
  test_unreadable_config_is_an_error ()
;;
