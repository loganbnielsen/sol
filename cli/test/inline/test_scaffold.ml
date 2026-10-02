let check_bool = Alcotest.(check bool)
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
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let template_root () =
  match Sol_cli_platform_assets.resolve () with
  | Ok assets -> Sol_cli_platform_assets.templates_root assets
  | Error error ->
    Alcotest.fail
      ("no scaffold templates: " ^ Sol_cli_platform_assets.error_to_string error)
;;

let tpl ~kind rel =
  match Sol_cli_scaffold_tree.text ~root:(template_root ()) ~kind ~rel with
  | Ok text -> text
  | Error message -> Alcotest.fail message
;;

let in_temp_dir f =
  let orig_cwd = Sys.getcwd () in
  let tmpdir = Filename.temp_file "sol-scaffold-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Sys.chdir tmpdir;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir orig_cwd;
      ignore (Sol_cli_fs.remove_tree tmpdir))
    f
;;

let in_workspace f =
  in_temp_dir
  @@ fun () ->
  write_file "sol.yml" "";
  f ()
;;

let test_mkdir_p_creates_nested_dirs () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_fs.mkdir_p "a/b/c" |> Result.get_ok;
  check_bool "nested directories created" true (Sys.is_directory "a/b/c")
;;

let test_mkdir_p_tolerates_existing_dir () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_fs.mkdir_p "a/b" |> Result.get_ok;
  check_bool "an existing directory is Ok" true (Result.is_ok (Sol_cli_fs.mkdir_p "a/b"))
;;

let test_mkdir_p_raises_on_blocked_path () =
  in_temp_dir
  @@ fun () ->
  let oc = open_out "blocker" in
  output_string oc "not a directory";
  close_out oc;
  check_bool
    "a file in the way is an Error"
    true
    (Result.is_error (Sol_cli_fs.mkdir_p "blocker/child"))
;;

let test_mkdir_p_raises_on_broken_symlink () =
  in_temp_dir
  @@ fun () ->
  Unix.symlink "does-not-exist" "broken-link";
  check_bool
    "a broken symlink is an Error"
    true
    (Result.is_error (Sol_cli_fs.mkdir_p "broken-link"))
;;

let test_mkdir_p_tolerates_symlink_to_real_directory () =
  in_temp_dir
  @@ fun () ->
  Unix.mkdir "real" 0o755;
  Unix.symlink "real" "link-to-real";
  check_bool
    "a symlink to a directory is Ok"
    true
    (Result.is_ok (Sol_cli_fs.mkdir_p "link-to-real"))
;;

let test_ci_workflow_created () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let path = "testapp/.github/workflows/sol-ci.yml" in
  check_bool "sol-ci.yml created" true (Sys.file_exists path)
;;

let test_deploy_workflow_created () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let path = "testapp/.github/workflows/deploy.yml" in
  check_bool "deploy.yml created" true (Sys.file_exists path)
;;

let test_deploy_workflow_passes_target () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/deploy.yml" in
  assert_contains "deploy.yml" content "SOL_TARGET";
  assert_contains "deploy.yml" content "sol deploy \"$SOL_TARGET\""
;;

let test_ci_contains_sol_deploy () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "sol deploy"
;;

let test_ci_deploy_steps_pass_target () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "SOL_TARGET";
  assert_contains "sol-ci.yml" content {|main.exe deploy "$SOL_TARGET"|}
;;

let test_ci_contains_emit_plan_to () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "--emit-plan-to"
;;

let test_ci_contains_emit_to () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "--emit-to"
;;

let test_ci_contains_dune_commands () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "dune build";
  assert_contains "sol-ci.yml" content "dune runtest"
;;

let test_schema_gate_is_run_in_ci () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let dune = read_file "testapp/test/dune" in
  let workflow = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "test/dune" dune "(test\n (name test_schemas)";
  assert_contains
    "sol-ci.yml"
    workflow
    "SCHEMA_REGISTRY_URL: ${{ secrets.SCHEMA_REGISTRY_URL }}"
;;

let test_ci_no_kubeconfig_in_build_job () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  check_bool "no KUBECONFIG in sol-ci.yml" false (contains content "KUBECONFIG_B64")
;;

let test_ci_registry_secrets () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "secrets.REGISTRY";
  assert_contains "sol-ci.yml" content "secrets.REGISTRY_USER";
  assert_contains "sol-ci.yml" content "secrets.REGISTRY_PASSWORD"
;;

let test_ci_contract_comment_present () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "Sol CI contract";
  assert_contains "sol-ci.yml" content "PHASE 1";
  assert_contains "sol-ci.yml" content "PHASE 2"
;;

let test_ci_contract_deploy_phase_uses_sol_deploy () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "sol deploy <target> --emit-plan-to";
  assert_contains "sol-ci.yml" content "sol deploy <target> --emit-to"
;;

let test_ci_no_raw_kubectl_apply () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  check_bool "no raw kubectl apply in sol-ci.yml" false (contains content "kubectl apply")
;;

let test_ci_build_images_has_todo_sol_build () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "TODO(sol-build)"
;;

let test_existing_files_still_generated () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let expected =
    [ "testapp/.ocamlformat"
    ; "testapp/.dockerignore"
    ; "testapp/dune-project"
    ; "testapp/README.md"
    ; "testapp/testapp.opam"
    ; "testapp/events/payments/charged.ml"
    ; "testapp/events/payments/dune"
    ; "testapp/lib/notification.ml"
    ; "testapp/test/test_charges.ml"
    ; "testapp/app/payments/charge_svc/bin/main.ml"
    ; "testapp/app/payments/charge_svc/sol.toml"
    ; "testapp/app/comms/notify_worker/bin/main.ml"
    ; "testapp/app/comms/notify_worker/sol.toml"
    ; "testapp/db/migrations/0001_notifications.sql"
    ; "testapp/db/migrations/0002_sol_outbox.sql"
    ; "testapp/db/migrations/0003_notifications_charge_id_unique.sql"
    ; "testapp/sol/environments.yml"
    ; "testapp/.gitignore"
    ]
  in
  expected
  |> List.iter (fun path ->
    check_bool (Printf.sprintf "%s exists" path) true (Sys.file_exists path));
  let count = ref 0 in
  let rec walk dir =
    Sys.readdir dir
    |> Array.iter (fun entry ->
      let full = Filename.concat dir entry in
      if full = "testapp/vendor"
      then ()
      else if Sys.is_directory full
      then walk full
      else incr count)
  in
  walk "testapp";
  check_bool "at least 21 files generated" true (!count >= 21)
;;

let test_scaffolded_workspace_has_a_real_deploy_target () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  Sys.chdir "testapp";
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Error e ->
    Alcotest.fail ("load_for_target failed: " ^ Sol_cli_config.error_to_string e)
  | Ok cfg ->
    let target = cfg.target in
    check_bool
      "prod/aws/us-east-1 is declared"
      true
      (Sol_cli_config.target_declared target)
;;

let test_workspace_has_dune_project () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/dune-project" in
  assert_contains "dune-project" content "(lang dune 3.0)"
;;

let test_dockerfile_paths_are_workspace_relative () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/app/payments/charge_svc/Dockerfile" in
  assert_contains
    "Dockerfile"
    content
    "COPY --from=build /workspace/_build/default/app/payments/charge_svc/bin/main.exe";
  assert_contains "Dockerfile" content "dune build app/payments/charge_svc/bin/main.exe";
  check_bool
    "Dockerfile does not include nested workspace path"
    false
    (contains content "_build/default/testapp/app/payments/charge_svc")
;;

let test_readme_migrate_hint_substituted () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/README.md" in
  assert_contains "README" content "sol migrate";
  check_bool "README has no template placeholder" false (contains content "{{name}}")
;;

let test_framework_dependency_declared_not_vendored () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  check_bool "no vendor/ directory is created" false (Sys.file_exists "testapp/vendor");
  let opam = read_file "testapp/testapp.opam" in
  List.iter
    (fun pkg -> assert_contains "workspace .opam declares framework dep" opam pkg)
    [ "sol-svc"; "sol-worker"; "sol-fn"; "sol-jobs"; "sol-obs"; "kafka-eio-service" ]
;;

let test_scaffold_compiles () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let built =
    Sol_cli_process.run (Sol_cli_process.cmd ~cwd:"testapp" [ "dune"; "build" ])
  in
  built |> Result.iter_error (fun e -> prerr_endline (Sol_cli_process.error_to_string e));
  check_bool
    "freshly scaffolded workspace builds with `dune build`"
    true
    (Result.is_ok built);
  let tested =
    Sol_cli_process.run
      (Sol_cli_process.cmd
         ~cwd:"testapp"
         ~env:[ "CI", "false" ]
         [ "dune"; "runtest"; "test" ])
  in
  tested |> Result.iter_error (fun e -> prerr_endline (Sol_cli_process.error_to_string e));
  check_bool "generated charge operation tests pass" true (Result.is_ok tested)
;;

let test_bare_fn_library_compiles () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  Sys.chdir "testapp";
  Sol_cli_cmd_new.new_fn "billing/invoice" |> Result.get_ok;
  let built =
    Sol_cli_process.run
      (Sol_cli_process.cmd [ "dune"; "build"; "app/billing/invoice_fn/lib/" ])
  in
  Sys.chdir "..";
  built |> Result.iter_error (fun e -> prerr_endline (Sol_cli_process.error_to_string e));
  check_bool
    "generic fn's own library target builds in isolation"
    true
    (Result.is_ok built)
;;

let test_charge_svc_publishes_kafka_event () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let handler = read_file "testapp/app/payments/charge_svc/lib/handler.ml" in
  let main_ml = read_file "testapp/app/payments/charge_svc/bin/main.ml" in
  assert_contains "handler" handler "publish_charged event";
  check_bool
    "handler does not insert notification directly"
    false
    (contains handler "Notification.insert");
  assert_contains "main" main_ml "Kafka_service.register";
  assert_contains "main" main_ml "Kafka_service.publish"
;;

let test_workspace_generated_json_decoders_are_result_based () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let event = read_file "testapp/events/payments/charged.ml" in
  let handler = read_file "testapp/app/payments/charge_svc/lib/handler.ml" in
  assert_contains "event" event "let required_string fields name";
  assert_contains "event" event "let required_int fields name";
  assert_contains "event" event "open Result.Syntax";
  assert_contains "event" event "let* id = required_string fields \"id\"";
  assert_contains "event" event "let* amount_cents = required_int fields \"amount_cents\"";
  assert_contains "event" event "Error (name ^ \" must be an integer\")";
  assert_contains "handler" handler "let decode_charge json";
  assert_contains "handler" handler "Response.bad_request msg";
  check_bool
    "handler has no default string fallback"
    false
    (contains handler "Option.value ~default:\"\"");
  check_bool
    "handler has no default int fallback"
    false
    (contains handler "Option.value ~default:0");
  check_bool
    "event has no missing-fields catch-all"
    false
    (contains event "missing required fields")
;;

let test_workspace_startup_helpers_are_flattened () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let svc_main = read_file "testapp/app/payments/charge_svc/bin/main.ml" in
  let worker_main = read_file "testapp/app/comms/notify_worker/bin/main.ml" in
  List.iter
    (fun (label, content) ->
       assert_contains label content "let fatal msg";
       assert_contains label content "let require_db_pool";
       assert_contains label content "Sol_obs.of_env";
       check_bool (label ^ " avoids failwith") false (contains content "failwith");
       check_bool
         (label ^ " avoids nested postgres_url match")
         false
         (contains content "let pool = match postgres_url");
       check_bool
         (label ^ " no longer hand-composes a Loki backend")
         false
         (contains content "Obs_loki.create"))
    [ "svc main", svc_main; "worker main", worker_main ]
;;

let test_parse_domain_name_normalizes_valid_name () =
  Alcotest.(check (result (pair string string) string))
    "normalized domain/name"
    (Ok ("payments", "charge_svc"))
    (Sol_cli_cmd_new.parse_domain_name "Payments/Charge-Svc")
;;

let test_parse_domain_name_rejects_malformed_names () =
  List.iter
    (fun arg ->
       match Sol_cli_cmd_new.parse_domain_name arg with
       | Ok (domain, name) ->
         Alcotest.failf "expected %S to be rejected, got (%S, %S)" arg domain name
       | Error msg ->
         assert_contains ("error for " ^ arg) msg "expected domain/name";
         assert_contains ("error for " ^ arg) msg arg)
    [ ""; "payments"; "payments/"; "/charge"; "payments/charge/extra" ]
;;

let test_bundle_layout_resolves_sol_home () =
  let tmpdir = Filename.temp_file "sol-bundle-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path) in
       mkdir_p (Filename.concat tmpdir "bin");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib");
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       touch (Filename.concat tmpdir "framework/ocaml/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib/dune");
       let result =
         let saved = Sys.getenv_opt "SOL_HOME" in
         Unix.putenv "SOL_HOME" tmpdir;
         let r =
           Result.to_option
             (Result.map Sol_cli_platform_assets.dir (Sol_cli_platform_assets.resolve ()))
         in
         (match saved with
          | None -> Unix.putenv "SOL_HOME" ""
          | Some v -> Unix.putenv "SOL_HOME" v);
         r
       in
       check_bool "bundle layout: infer_sol_home resolves to Some" true (result <> None);
       check_bool "bundle layout: resolved path matches tmpdir" true (result = Some tmpdir))
;;

let test_incomplete_bundle_rejected () =
  let tmpdir = Filename.temp_file "sol-bundle-partial-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path) in
       mkdir_p (Filename.concat tmpdir "framework/ocaml/sol-svc/lib");
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       touch (Filename.concat tmpdir "framework/ocaml/sol-svc/lib/dune");
       let result =
         let saved = Sys.getenv_opt "SOL_HOME" in
         Unix.putenv "SOL_HOME" tmpdir;
         let r =
           Result.to_option
             (Result.map Sol_cli_platform_assets.dir (Sol_cli_platform_assets.resolve ()))
         in
         (match saved with
          | None -> Unix.putenv "SOL_HOME" ""
          | Some v -> Unix.putenv "SOL_HOME" v);
         r
       in
       check_bool "incomplete bundle: infer_sol_home returns None" true (result = None))
;;

let test_ancestor_walk_finds_bundle_root () =
  let tmpdir = Filename.temp_file "sol-ancestor-walk-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path) in
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       mkdir_p (Filename.concat tmpdir "bin");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib");
       touch (Filename.concat tmpdir "framework/ocaml/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib/dune");
       check_bool
         "is_sol_home returns true for valid bundle root"
         true
         (Sol_cli_platform_assets.is_checkout tmpdir);
       let bin_dir = Filename.concat tmpdir "bin" in
       let result =
         Sol_cli_platform_assets.find_ancestor Sol_cli_platform_assets.is_checkout bin_dir
       in
       check_bool "find_ancestor: returns Some" true (result <> None);
       check_bool
         "find_ancestor: resolved path matches bundle root"
         true
         (result = Some tmpdir))
;;

let test_ancestor_walk_skips_build_context () =
  let tmpdir = Filename.temp_file "sol-build-context-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path) in
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       mkdir_p (Filename.concat tmpdir "framework/ocaml/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib");
       touch (Filename.concat tmpdir "framework/ocaml/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib/dune");
       let build_default = Filename.concat tmpdir "_build/default" in
       mkdir_p (Filename.concat build_default "framework/ocaml/sol-svc/lib");
       mkdir_p (Filename.concat build_default "framework/ocaml/kafka-eio-service/lib");
       touch (Filename.concat build_default "framework/ocaml/sol-svc/lib/dune");
       touch (Filename.concat build_default "framework/ocaml/kafka-eio-service/lib/dune");
       check_bool
         "is_sol_home rejects _build/default"
         false
         (Sol_cli_platform_assets.is_checkout build_default);
       let start = Filename.concat build_default "cli/test" in
       let result =
         Sol_cli_platform_assets.find_ancestor Sol_cli_platform_assets.is_checkout start
       in
       check_bool "ancestor walk skips _build/default" true (result = Some tmpdir))
;;

let test_worker_has_no_ack_param () =
  in_workspace
  @@ fun () ->
  Sol_cli_cmd_new.new_worker "comms/notify" |> Result.get_ok;
  let lib = read_file "app/comms/notify_worker/lib/notify_worker.ml" in
  check_bool "generated worker does not reference ~ack" false (contains lib "~ack");
  assert_contains "worker lib" lib "~trace_ctx";
  assert_contains "worker lib" lib "Printf.printf";
  assert_contains "worker lib" lib "Worker.Ack"
;;

let count_unapplied ~root =
  match Sol_cli_workspace_model.load ~root with
  | Ok facts -> Sol_cli_workspace_model.count_unapplied_migrations facts
  | Error e -> Alcotest.fail ("workspace model failed to load: " ^ e)
;;

let test_pending_migrations_no_dir () =
  let tmpdir = Filename.temp_file "sol-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () -> check_bool "no mig dir → 0" true (count_unapplied ~root:tmpdir = 0))
;;

let test_pending_migrations_empty_dir () =
  let tmpdir = Filename.temp_file "sol-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       Sol_cli_fs.mkdir_p (Filename.concat tmpdir "db/migrations") |> Result.get_ok;
       check_bool "empty dir → 0" true (count_unapplied ~root:tmpdir = 0))
;;

let test_pending_migrations_counts_sql_files () =
  let tmpdir = Filename.temp_file "sol-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       Sol_cli_fs.mkdir_p (Filename.concat tmpdir "db/migrations") |> Result.get_ok;
       let touch name =
         let path = Printf.sprintf "%s/db/migrations/%s" tmpdir name in
         let oc = open_out path in
         close_out oc
       in
       touch "0001_init.sql";
       touch "0002_add_column.sql";
       touch "README.md";
       check_bool "two sql files → 2" true (count_unapplied ~root:tmpdir = 2))
;;

let test_pending_migrations_ignores_down_migrations () =
  let tmpdir = Filename.temp_file "sol-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       Sol_cli_fs.mkdir_p (Filename.concat tmpdir "db/migrations") |> Result.get_ok;
       let touch name =
         let path = Printf.sprintf "%s/db/migrations/%s" tmpdir name in
         let oc = open_out path in
         close_out oc
       in
       touch "0001_init.sql";
       touch "0001_init.down.sql";
       check_bool "down files are not migrations" true (count_unapplied ~root:tmpdir = 1))
;;

let test_pending_migrations_workspace_scaffold () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  check_bool
    "scaffold workspace → 3 migration files"
    true
    (count_unapplied ~root:"testapp" = 3)
;;

let test_scaffold_event_topic_matches_module () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let topic = "testapp-payments-charges" in
  assert_contains
    "scaffolded events/payments/sol.toml"
    (read_file "testapp/events/payments/sol.toml")
    (Printf.sprintf "topics = [%S]" topic);
  assert_contains
    "scaffolded events/payments/charged.ml"
    (read_file "testapp/events/payments/charged.ml")
    (Printf.sprintf "topic_name_exn %S" topic)
;;

let test_golden_ci_workflow () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let actual = read_file "testapp/.github/workflows/sol-ci.yml" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"; "Name", "Testapp" ]
      (tpl ~kind:"workspace" ".github/workflows/sol-ci.yml")
  in
  Alcotest.(check string) "sol-ci.yml golden" expected actual
;;

let test_golden_dockerfile () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let actual = read_file "testapp/app/payments/charge_svc/Dockerfile" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"
      ; "Name", "Testapp"
      ; "basename", "testapp"
      ; "repo_dir", "app/payments/charge_svc"
      ; "binary", "testapp-charge-svc"
      ]
      (tpl ~kind:"workspace" "app/payments/charge_svc/Dockerfile")
  in
  Alcotest.(check string) "Dockerfile golden" expected actual
;;

let test_golden_svc_bin_ml () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let actual = read_file "testapp/app/payments/charge_svc/bin/main.ml" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"; "Name", "Testapp" ]
      (tpl ~kind:"workspace" "app/payments/charge_svc/bin/main.ml")
  in
  Alcotest.(check string) "svc bin/main.ml golden" expected actual
;;

let test_golden_worker_bin_ml () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let actual = read_file "testapp/app/comms/notify_worker/bin/main.ml" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"; "Name", "Testapp" ]
      (tpl ~kind:"workspace" "app/comms/notify_worker/bin/main.ml")
  in
  Alcotest.(check string) "worker bin/main.ml golden" expected actual
;;

let test_golden_test_dune () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let actual = read_file "testapp/test/dune" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"; "Name", "Testapp" ]
      (tpl ~kind:"workspace" "test/dune")
  in
  Alcotest.(check string) "test/dune golden" expected actual
;;

let component_vars ~suffix ~mod_ =
  let ws = Sol_cli_scaffold.normalize (Filename.basename (Sys.getcwd ())) in
  let dir = Printf.sprintf "app/comms/notify_%s" suffix in
  [ "lib", Printf.sprintf "%s_comms_notify_%s" ws suffix
  ; "dir", dir
  ; "repo_dir", dir
  ; "name", "notify"
  ; "domain", "comms"
  ; "Mod", mod_
  ; "binary", "notify-" ^ suffix
  ; "basename", ws
  ]
;;

let check_generated_file label path expected =
  let actual = read_file path in
  Alcotest.(check string) label expected actual
;;

let test_golden_new_svc_files () =
  in_workspace
  @@ fun () ->
  Sol_cli_cmd_new.new_svc "comms/notify" |> Result.get_ok;
  let v = component_vars ~suffix:"svc" ~mod_:"Handler" in
  check_generated_file
    "svc handler"
    "app/comms/notify_svc/lib/handler.ml"
    (tpl ~kind:"svc" "lib/handler.ml");
  check_generated_file
    "svc lib dune"
    "app/comms/notify_svc/lib/dune"
    (Sol_cli_scaffold.subst v (tpl ~kind:"svc" "lib/dune"));
  check_generated_file
    "svc bin main"
    "app/comms/notify_svc/bin/main.ml"
    (Sol_cli_scaffold.subst v (tpl ~kind:"svc" "bin/main.ml"));
  check_generated_file
    "svc bin dune"
    "app/comms/notify_svc/bin/dune"
    (Sol_cli_scaffold.subst v (tpl ~kind:"svc" "bin/dune"));
  check_generated_file
    "svc sol.toml"
    "app/comms/notify_svc/sol.toml"
    (tpl ~kind:"svc" "sol.toml");
  check_generated_file
    "svc Dockerfile"
    "app/comms/notify_svc/Dockerfile"
    (Sol_cli_scaffold.subst v (tpl ~kind:"svc" "Dockerfile"))
;;

let test_golden_new_worker_files () =
  in_workspace
  @@ fun () ->
  Sol_cli_cmd_new.new_worker "comms/notify" |> Result.get_ok;
  let v = component_vars ~suffix:"worker" ~mod_:"Notify_worker" in
  check_generated_file
    "worker lib"
    "app/comms/notify_worker/lib/notify_worker.ml"
    (Sol_cli_scaffold.subst v (tpl ~kind:"worker" "lib/{{name}}_worker.ml"));
  check_generated_file
    "worker lib dune"
    "app/comms/notify_worker/lib/dune"
    (Sol_cli_scaffold.subst v (tpl ~kind:"worker" "lib/dune"));
  check_generated_file
    "worker bin main"
    "app/comms/notify_worker/bin/main.ml"
    (Sol_cli_scaffold.subst v (tpl ~kind:"worker" "bin/main.ml"));
  check_generated_file
    "worker bin dune"
    "app/comms/notify_worker/bin/dune"
    (Sol_cli_scaffold.subst v (tpl ~kind:"worker" "bin/dune"));
  check_generated_file
    "worker sol.toml"
    "app/comms/notify_worker/sol.toml"
    (tpl ~kind:"worker" "sol.toml");
  check_generated_file
    "worker Dockerfile"
    "app/comms/notify_worker/Dockerfile"
    (Sol_cli_scaffold.subst v (tpl ~kind:"worker" "Dockerfile"))
;;

let test_golden_new_fn_files () =
  in_workspace
  @@ fun () ->
  Sol_cli_cmd_new.new_fn "comms/notify" |> Result.get_ok;
  let v = component_vars ~suffix:"fn" ~mod_:"Notify_fn" in
  check_generated_file
    "fn lib"
    "app/comms/notify_fn/lib/notify_fn.ml"
    (Sol_cli_scaffold.subst v (tpl ~kind:"fn" "lib/{{name}}_fn.ml"));
  check_generated_file
    "fn lib dune"
    "app/comms/notify_fn/lib/dune"
    (Sol_cli_scaffold.subst v (tpl ~kind:"fn" "lib/dune"));
  check_generated_file
    "fn bin main"
    "app/comms/notify_fn/bin/main.ml"
    (Sol_cli_scaffold.subst v (tpl ~kind:"fn" "bin/main.ml"));
  check_generated_file
    "fn bin dune"
    "app/comms/notify_fn/bin/dune"
    (Sol_cli_scaffold.subst v (tpl ~kind:"fn" "bin/dune"));
  check_generated_file
    "fn sol.toml"
    "app/comms/notify_fn/sol.toml"
    (tpl ~kind:"fn" "sol.toml");
  check_generated_file
    "fn Dockerfile"
    "app/comms/notify_fn/Dockerfile"
    (Sol_cli_scaffold.subst v (tpl ~kind:"fn" "Dockerfile"))
;;

let test_generated_workload_declares_its_language () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  Sys.chdir "testapp";
  Sol_cli_cmd_new.new_svc "payments/charge" |> Result.get_ok;
  let after_first = read_file "sol.yml" in
  assert_contains "declares the workload" after_first "charge_svc:";
  assert_contains "declares the language" after_first "language: ocaml";
  (match Sol_cli_config.sol_yml_services ~root:"." with
   | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
   | Ok services ->
     let svc =
       List.find
         (fun (s : Sol_cli_config.service) -> String.equal s.name "charge_svc")
         services
     in
     Alcotest.(check (option string))
       "the reader sees the declaration"
       (Some "ocaml")
       (Option.map Sol_cli_compat.to_string svc.language));
  (match Sol_cli_workspace_model.load ~root:"." with
   | Error e -> Alcotest.fail ("workspace model failed to load: " ^ e)
   | Ok facts ->
     let findings = Sol_cli_check.run ~facts in
     Alcotest.(check bool)
       "a scaffolded workspace is check-clean"
       true
       (List.length findings = 0));
  Sol_cli_cmd_new.new_svc "payments/charge" |> Result.get_ok;
  Alcotest.(check string)
    "sol.yml is untouched by the second run"
    after_first
    (read_file "sol.yml")
;;

let test_workspace_report_points_at_its_readme () =
  in_temp_dir
  @@ fun () ->
  let (), reported =
    Sol_cli_report.collect (fun () ->
      Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok)
  in
  let text =
    reported
    |> List.filter_map (fun (level, text) ->
      match level with
      | Logs.App -> Some text
      | _ -> None)
    |> String.concat "\n"
  in
  assert_contains "new workspace report" text "README.md";
  check_bool
    "the README it names exists in the generated workspace"
    true
    (Sys.file_exists "testapp/README.md")
;;

let%test "generated workspace report: names the README it generated" =
  test_workspace_report_points_at_its_readme ()
;;

let%test "ci_workflow: sol-ci.yml created" = test_ci_workflow_created ()
let%test "ci_workflow: deploy.yml still created" = test_deploy_workflow_created ()
let%test "ci_workflow: deploy.yml passes target" = test_deploy_workflow_passes_target ()
let%test "ci_workflow: contains sol deploy" = test_ci_contains_sol_deploy ()
let%test "ci_workflow: deploy steps pass target" = test_ci_deploy_steps_pass_target ()
let%test "ci_workflow: --emit-plan-to present" = test_ci_contains_emit_plan_to ()
let%test "ci_workflow: --emit-to present" = test_ci_contains_emit_to ()
let%test "ci_workflow: dune build + runtest" = test_ci_contains_dune_commands ()
let%test "ci_workflow: schema gate runs in CI" = test_schema_gate_is_run_in_ci ()

let%test "ci_workflow: no KUBECONFIG_B64 in workflow" =
  test_ci_no_kubeconfig_in_build_job ()
;;

let%test "ci_workflow: registry secret placeholders" = test_ci_registry_secrets ()
let%test "ci_workflow: CI contract comment present" = test_ci_contract_comment_present ()

let%test "ci_workflow: deploy phase uses sol deploy" =
  test_ci_contract_deploy_phase_uses_sol_deploy ()
;;

let%test "ci_workflow: no raw kubectl apply" = test_ci_no_raw_kubectl_apply ()

let%test "ci_workflow: build-images has TODO(sol-build)" =
  test_ci_build_images_has_todo_sol_build ()
;;

let%test
    "generated_workloads_declare_their_language: sol new records the workload's declared \
     language"
  =
  test_generated_workload_declares_its_language ()
;;

let%test "existing_files: all prior files still present" =
  test_existing_files_still_generated ()
;;

let%test "existing_files: has a real deploy target" =
  test_scaffolded_workspace_has_a_real_deploy_target ()
;;

let%test "existing_files: dune-project generated" = test_workspace_has_dune_project ()

let%test "existing_files: Dockerfile paths relative" =
  test_dockerfile_paths_are_workspace_relative ()
;;

let%test "existing_files: README hints substituted" =
  test_readme_migrate_hint_substituted ()
;;

let%test "existing_files: framework dep declared, not vendored" =
  test_framework_dependency_declared_not_vendored ()
;;

let%test "existing_files: scaffold actually compiles" = test_scaffold_compiles ()
let%test "existing_files: bare fn library compiles" = test_bare_fn_library_compiles ()

let%test "existing_files: charge_svc publishes event" =
  test_charge_svc_publishes_kafka_event ()
;;

let%test "existing_files: JSON decoders are result based" =
  test_workspace_generated_json_decoders_are_result_based ()
;;

let%test "existing_files: startup helpers are flattened" =
  test_workspace_startup_helpers_are_flattened ()
;;

let%test "worker_ack: generated worker has no ack param" = test_worker_has_no_ack_param ()

let%test "domain_name_parser: normalizes valid domain/name" =
  test_parse_domain_name_normalizes_valid_name ()
;;

let%test "domain_name_parser: rejects malformed names" =
  test_parse_domain_name_rejects_malformed_names ()
;;

let%test "bundle_resolution: complete bundle layout resolves sol_home" =
  test_bundle_layout_resolves_sol_home ()
;;

let%test "bundle_resolution: incomplete bundle is rejected" =
  test_incomplete_bundle_rejected ()
;;

let%test "bundle_resolution: ancestor walk finds bundle root from bin/" =
  test_ancestor_walk_finds_bundle_root ()
;;

let%test "bundle_resolution: ancestor walk skips _build context" =
  test_ancestor_walk_skips_build_context ()
;;

let%test "pending_migrations: no db/migrations dir → 0" =
  test_pending_migrations_no_dir ()
;;

let%test "pending_migrations: empty db/migrations dir → 0" =
  test_pending_migrations_empty_dir ()
;;

let%test "pending_migrations: counts only .sql files" =
  test_pending_migrations_counts_sql_files ()
;;

let%test "pending_migrations: a .down.sql reversal is not counted" =
  test_pending_migrations_ignores_down_migrations ()
;;

let%test "pending_migrations: scaffold workspace → 1 migration" =
  test_pending_migrations_workspace_scaffold ()
;;

let%test "pending_migrations: scaffolded event topic matches its module" =
  test_scaffold_event_topic_matches_module ()
;;

let%test "golden: sol-ci.yml" = test_golden_ci_workflow ()
let%test "golden: charge_svc Dockerfile" = test_golden_dockerfile ()
let%test "golden: charge_svc bin/main.ml" = test_golden_svc_bin_ml ()
let%test "golden: notify_worker bin/main.ml" = test_golden_worker_bin_ml ()
let%test "golden: test/dune" = test_golden_test_dune ()
let%test "golden: new svc files" = test_golden_new_svc_files ()
let%test "golden: new worker files" = test_golden_new_worker_files ()
let%test "golden: new fn files" = test_golden_new_fn_files ()
let%test "mkdir_p: creates nested directories" = test_mkdir_p_creates_nested_dirs ()

let%test "mkdir_p: tolerates an existing directory" =
  test_mkdir_p_tolerates_existing_dir ()
;;

let%test "mkdir_p: raises when a path component is a file" =
  test_mkdir_p_raises_on_blocked_path ()
;;

let%test "mkdir_p: raises on a broken symlink" = test_mkdir_p_raises_on_broken_symlink ()

let%test "mkdir_p: tolerates a symlink to a real directory" =
  test_mkdir_p_tolerates_symlink_to_real_directory ()
;;
