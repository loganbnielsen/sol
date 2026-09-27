(* Tests for Sol workspace scaffold (cmd_new.ml / sol new workspace).
   Calls new_workspace in a temp directory and asserts that the expected
   files are created with the correct content.  No build or cluster needed. *)

(* ── helpers ──────────────────────────────────────────────────────────────── *)

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

(* REFAC-128: the templates are files under platform/shared/templates/<kind>/,
   resolved as Sol assets. The expectations below are the same bytes they always
   were; only where they are read from changed. *)
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

(* Run [f] inside a fresh temp directory, then restore cwd and delete the tree. *)
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

(* FEAT-104: `sol new svc|worker|fn` records the generated unit in the workspace
   manifest -- which is what makes "every workload has a declared language" true
   for a workspace Sol created -- so creating a unit needs a workspace. These
   tests used to scaffold a bare unit in an empty directory. *)
let in_workspace f =
  in_temp_dir
  @@ fun () ->
  write_file "sol.yml" "";
  f ()
;;

(* ── mkdir_p ──────────────────────────────────────────────────────────────── *)

(* Regression test: mkdir_p used to shell out to `mkdir -p` and discard the
   exit code, so a blocked path silently proceeded as if it had succeeded.
   REFAC-134: the implementation is Sol_cli_fs.mkdir_p, and a failure is its
   Error rather than an exception. *)
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

(* Regression test: Sys.file_exists returns false for a broken symlink (it
   follows the link and finds nothing), so the old implementation fell
   through to Unix.mkdir, got EEXIST (the symlink dirent itself exists),
   and treated that as success — silently leaving a still-unusable path
   exactly like the original shell-out bug this fix was meant to eliminate. *)
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

(* ── scaffold tests ───────────────────────────────────────────────────────── *)

(* Verify that sol-ci.yml is generated *)
let test_ci_workflow_created () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let path = "testapp/.github/workflows/sol-ci.yml" in
  check_bool "sol-ci.yml created" true (Sys.file_exists path)
;;

(* Verify that the existing deploy.yml is still generated *)
let test_deploy_workflow_created () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let path = "testapp/.github/workflows/deploy.yml" in
  check_bool "deploy.yml created" true (Sys.file_exists path)
;;

(* FEAT-026: deploy.yml's real (non-comment) `sol deploy` invocation passes
   a target via a SOL_TARGET repo variable, documented in the header. *)
let test_deploy_workflow_passes_target () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/deploy.yml" in
  assert_contains "deploy.yml" content "SOL_TARGET";
  assert_contains "deploy.yml" content "sol deploy \"$SOL_TARGET\""
;;

(* Verify that sol-ci.yml contains 'sol deploy' *)
let test_ci_contains_sol_deploy () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "sol deploy"
;;

(* FEAT-026: sol-ci.yml's two real (non-comment) `main.exe deploy` steps —
   Export deployment plan, Emit GitOps manifests — must actually pass a
   target, not just have a comment above them claiming one. An earlier
   pass of this ticket updated only the comments and missed this: the
   generated workflow failed with "required argument TARGET is missing"
   on the very first push, since a substring check on "sol deploy" alone
   (test_ci_contains_sol_deploy above) passes either way. *)
let test_ci_deploy_steps_pass_target () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "SOL_TARGET";
  assert_contains "sol-ci.yml" content {|main.exe deploy "$SOL_TARGET"|}
;;

(* Verify that sol-ci.yml contains '--emit-plan-to' (FEAT-008 integration) *)
let test_ci_contains_emit_plan_to () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "--emit-plan-to"
;;

(* Verify that sol-ci.yml contains '--emit-to' (GitOps mode) *)
let test_ci_contains_emit_to () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "--emit-to"
;;

(* Verify that sol-ci.yml contains 'dune build' and 'dune runtest' *)
let test_ci_contains_dune_commands () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "dune build";
  assert_contains "sol-ci.yml" content "dune runtest"
;;

(* Verify no KUBECONFIG in the test/build job — cluster creds must stay out *)
let test_ci_no_kubeconfig_in_build_job () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  (* KUBECONFIG must not appear as a required secret or env var *)
  check_bool "no KUBECONFIG in sol-ci.yml" false (contains content "KUBECONFIG_B64")
;;

(* Verify that registry credentials are referenced as secrets (placeholders) *)
let test_ci_registry_secrets () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "secrets.REGISTRY";
  assert_contains "sol-ci.yml" content "secrets.REGISTRY_USER";
  assert_contains "sol-ci.yml" content "secrets.REGISTRY_PASSWORD"
;;

(* Verify that the CI contract comment block is present — PHASE 1 and PHASE 2 *)
let test_ci_contract_comment_present () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "Sol CI contract";
  assert_contains "sol-ci.yml" content "PHASE 1";
  assert_contains "sol-ci.yml" content "PHASE 2"
;;

(* Verify that the deploy phase comment names sol deploy as the typed contract *)
let test_ci_contract_deploy_phase_uses_sol_deploy () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  (* The contract comment block must reference the sol deploy command,
     including the required <env>/<provider>/<region> target (FEAT-026) *)
  assert_contains "sol-ci.yml" content "sol deploy <target> --emit-plan-to";
  assert_contains "sol-ci.yml" content "sol deploy <target> --emit-to"
;;

(* Verify that no raw kubectl apply appears in the generated workflow — all
   cluster changes must go through sol deploy *)
let test_ci_no_raw_kubectl_apply () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  check_bool "no raw kubectl apply in sol-ci.yml" false (contains content "kubectl apply")
;;

(* Verify that the build-images step retains the TODO(sol-build) marker so
   future contributors know this step will be replaced by sol build *)
let test_ci_build_images_has_todo_sol_build () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "TODO(sol-build)"
;;

(* Verify that other expected workspace files are still present *)
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
    ; "testapp/app/payments/charge_svc/bin/main.ml"
    ; "testapp/app/payments/charge_svc/sol.toml"
    ; "testapp/app/comms/notify_worker/bin/main.ml"
    ; "testapp/app/comms/notify_worker/sol.toml"
    ; "testapp/db/migrations/0001_notifications.sql"
    ; "testapp/sol/environments.yml"
    ; "testapp/.gitignore"
    ]
  in
  expected
  |> List.iter (fun path ->
    check_bool (Printf.sprintf "%s exists" path) true (Sys.file_exists path));
  (* quick count: at least 21 files *)
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

(* FEAT-026 follow-up: `sol deploy` refuses a target that sol/environments.yml
   does not declare, even with an empty body (see cmd_deploy.ml's strict
   declaration check) -- a freshly scaffolded
   workspace must ship one so the acceptance criteria's own
   `sol deploy prod/aws/us-east-1 --dry-run` works with zero manual setup. *)
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

(* DEC-025: `sol new` must NOT vendor framework source into the workspace. The
   workspace owns its framework dependency through its own .opam declaration and
   resolves it from the opam switch. A vendored copy would make the framework's
   Dune files part of the *consumer's* Dune project -- the coupling DEC-024
   forbids, and provably incompatible with the framework being a package at all. *)
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

(* Regression test: the scaffold templates compiled to string literals in
   sol_cli_scaffold_templates.ml are never type-checked by this test suite
   itself (only string-matched) -- a template with a real type error or an
   unused-value warning promoted to an error by dune's default dev profile
   can silently ship. Actually building the generated workspace is the only
   way to catch that. This is slow (a real `dune build`) relative to the
   rest of this suite, deliberately -- there is no cheaper way to verify a
   generated OCaml program actually compiles. *)
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
    (Result.is_ok built)
;;

(* Regression test for BUG-007/BUG-011: `test_scaffold_compiles` above does
   a whole-project `dune build`, which can silently mask a missing
   `(libraries ...)` entry on one component's own lib stanza if some other
   already-correct target in the same build happens to pull in the same
   dependency first. Building just the new fn's own library target, in a
   domain no other scaffolded component touches, is the only way to catch
   that a generic-fn scaffold's library stanza is missing its own
   `sol_fn` dependency. *)
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

(* ── bundle source resolution tests ──────────────────────────────────────── *)

(* infer_sol_home must resolve a release-bundle SOL_HOME: both sentinel dune
   files present, per is_sol_home. *)
let test_bundle_layout_resolves_sol_home () =
  let tmpdir = Filename.temp_file "sol-bundle-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       (* Create the bundle directory structure *)
       let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path) in
       mkdir_p (Filename.concat tmpdir "bin");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib");
       (* Create the two sentinel dune files that is_sol_home checks *)
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       touch (Filename.concat tmpdir "framework/ocaml/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib/dune");
       (* Point SOL_HOME at the bundle root — infer_sol_home should accept it *)
       let result =
         let saved = Sys.getenv_opt "SOL_HOME" in
         Unix.putenv "SOL_HOME" tmpdir;
         let r =
           Result.to_option
             (Result.map Sol_cli_platform_assets.dir (Sol_cli_platform_assets.resolve ()))
         in
         (match saved with
          | None -> Unix.putenv "SOL_HOME" "" (* can't unset, but empty won't match *)
          | Some v -> Unix.putenv "SOL_HOME" v);
         r
       in
       check_bool "bundle layout: infer_sol_home resolves to Some" true (result <> None);
       check_bool "bundle layout: resolved path matches tmpdir" true (result = Some tmpdir))
;;

(* Verify that a directory missing the kafka-eio-service sentinel is rejected.
   This guards against accidentally accepting a partial bundle. *)
let test_incomplete_bundle_rejected () =
  let tmpdir = Filename.temp_file "sol-bundle-partial-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () ->
       let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path) in
       (* Only create the sol-svc sentinel, not the kafka-eio-service one *)
       mkdir_p (Filename.concat tmpdir "framework/ocaml/sol-svc/lib");
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       touch (Filename.concat tmpdir "framework/ocaml/sol-svc/lib/dune");
       (* SOL_HOME pointing here should be rejected — kafka-eio-service sentinel missing *)
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

(* Verify that find_ancestor + is_sol_home resolve the bundle root when starting
   from a simulated bin/ subdirectory — this is the primary runtime path used
   when a user downloads the release bundle and runs the binary directly.
   SOL_HOME is deliberately NOT set during this test. *)
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
       (* Create the bundle layout: tmpdir/bin/, tmpdir/framework/... *)
       mkdir_p (Filename.concat tmpdir "bin");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib");
       touch (Filename.concat tmpdir "framework/ocaml/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib/dune");
       (* is_sol_home should accept the bundle root *)
       check_bool
         "is_sol_home returns true for valid bundle root"
         true
         (Sol_cli_platform_assets.is_checkout tmpdir);
       (* find_ancestor starting from the bin/ subdirectory should walk up to tmpdir *)
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

(* BUG-017: the ancestor walk must skip `_build/default` even when dune has
   mirrored the framework sentinel files there. If it did not, CLI tests run
   from `_build/default/cli/test` would resolve SOL_HOME to the build tree
   and fail against missing source-side files/artifacts. *)
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
       (* A real source/release root: tmpdir/framework/... *)
       mkdir_p (Filename.concat tmpdir "framework/ocaml/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib");
       touch (Filename.concat tmpdir "framework/ocaml/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/ocaml/kafka-eio-service/lib/dune");
       (* The misleading build context: tmpdir/_build/default/framework/... *)
       let build_default = Filename.concat tmpdir "_build/default" in
       mkdir_p (Filename.concat build_default "framework/ocaml/sol-svc/lib");
       mkdir_p (Filename.concat build_default "framework/ocaml/kafka-eio-service/lib");
       touch (Filename.concat build_default "framework/ocaml/sol-svc/lib/dune");
       touch (Filename.concat build_default "framework/ocaml/kafka-eio-service/lib/dune");
       check_bool
         "is_sol_home rejects _build/default"
         false
         (Sol_cli_platform_assets.is_checkout build_default);
       (* Walk from a simulated test executable under the build context. *)
       let start = Filename.concat build_default "cli/test" in
       let result =
         Sol_cli_platform_assets.find_ancestor Sol_cli_platform_assets.is_checkout start
       in
       check_bool "ancestor walk skips _build/default" true (result = Some tmpdir))
;;

(* The framework acknowledges automatically after handle returns Worker.Ack; a
   generated worker must have no ~ack param to call, misorder, or forget. *)
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

(* ── count_unapplied_migrations tests ───────────────────────────────────── *)

(* REFAC-130: the count is a named function over the workspace model's
   migrations, so a bare directory is loaded through the same loader a command
   uses. *)
let count_unapplied ~root =
  match Sol_cli_workspace_model.load ~root with
  | Ok facts -> Sol_cli_workspace_model.count_unapplied_migrations facts
  | Error e -> Alcotest.fail ("workspace model failed to load: " ^ e)
;;

(* No db/migrations directory → count is 0 *)
let test_pending_migrations_no_dir () =
  let tmpdir = Filename.temp_file "sol-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () -> check_bool "no mig dir → 0" true (count_unapplied ~root:tmpdir = 0))
;;

(* db/migrations exists but is empty → count is 0 *)
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

(* db/migrations with two .sql files → count is 2 *)
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
       (* non-.sql — must not be counted *)
       check_bool "two sql files → 2" true (count_unapplied ~root:tmpdir = 2))
;;

(* A [.down.sql] reversal is not a migration of its own, so it is not counted. *)
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

(* workspace scaffold generates one .sql file → count is 1 *)
let test_pending_migrations_workspace_scaffold () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp" |> Result.get_ok;
  check_bool
    "scaffold workspace → 1 migration file"
    true
    (count_unapplied ~root:"testapp" = 1)
;;

(* ── golden tests ────────────────────────────────────────────────────────── *)

(* Golden: sol-ci.yml is byte-for-byte equivalent to the template source after
   substitution of {{name}}.  Any change to the template is visible in this diff. *)
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

(* Golden: charge_svc Dockerfile is byte-for-byte equivalent. *)
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

(* Golden: charge_svc bin/main.ml *)
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

(* Golden: notify_worker bin/main.ml *)
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

(* Golden: test/dune — exact content check so scaffold schema-test regressions
   show up as a readable diff rather than a silent missing-file failure. *)
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
    (* DEC-025: mirrors component_scaffold's v -- the workspace .opam basename. *)
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

(* ── entry point ─────────────────────────────────────────────────────────── *)

(* FEAT-104: a generated workload declares its language, and Sol knows it because
   it wrote the unit. The manifest is hand-maintained, so this is also the
   end-to-end proof that the editor lands the declaration in a real generated
   workspace -- and that a scaffolded workspace is check-clean, with every
   workload declared. *)
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
  (* The scaffolded workspace is check-clean: no undeclared workload, nothing to
     fix by hand. *)
  (match Sol_cli_workspace_model.load ~root:"." with
   | Error e -> Alcotest.fail ("workspace model failed to load: " ^ e)
   | Ok facts ->
     let findings = Sol_cli_check.run ~facts in
     Alcotest.(check bool)
       "a scaffolded workspace is check-clean"
       true
       (List.length findings = 0));
  (* Re-running is idempotent: the unit is rewritten, the manifest is not. *)
  Sol_cli_cmd_new.new_svc "payments/charge" |> Result.get_ok;
  Alcotest.(check string)
    "sol.yml is untouched by the second run"
    after_first
    (read_file "sol.yml")
;;

let () =
  Alcotest.run
    "scaffold"
    [ ( "ci_workflow"
      , [ Alcotest.test_case "sol-ci.yml created" `Quick test_ci_workflow_created
        ; Alcotest.test_case
            "deploy.yml still created"
            `Quick
            test_deploy_workflow_created
        ; Alcotest.test_case
            "deploy.yml passes target"
            `Quick
            test_deploy_workflow_passes_target
        ; Alcotest.test_case "contains sol deploy" `Quick test_ci_contains_sol_deploy
        ; Alcotest.test_case
            "deploy steps pass target"
            `Quick
            test_ci_deploy_steps_pass_target
        ; Alcotest.test_case "--emit-plan-to present" `Quick test_ci_contains_emit_plan_to
        ; Alcotest.test_case "--emit-to present" `Quick test_ci_contains_emit_to
        ; Alcotest.test_case "dune build + runtest" `Quick test_ci_contains_dune_commands
        ; Alcotest.test_case
            "no KUBECONFIG_B64 in workflow"
            `Quick
            test_ci_no_kubeconfig_in_build_job
        ; Alcotest.test_case
            "registry secret placeholders"
            `Quick
            test_ci_registry_secrets
        ; Alcotest.test_case
            "CI contract comment present"
            `Quick
            test_ci_contract_comment_present
        ; Alcotest.test_case
            "deploy phase uses sol deploy"
            `Quick
            test_ci_contract_deploy_phase_uses_sol_deploy
        ; Alcotest.test_case "no raw kubectl apply" `Quick test_ci_no_raw_kubectl_apply
        ; Alcotest.test_case
            "build-images has TODO(sol-build)"
            `Quick
            test_ci_build_images_has_todo_sol_build
        ] )
    ; ( "generated_workloads_declare_their_language"
      , [ Alcotest.test_case
            "sol new records the workload's declared language"
            `Quick
            test_generated_workload_declares_its_language
        ] )
    ; ( "existing_files"
      , [ Alcotest.test_case
            "all prior files still present"
            `Quick
            test_existing_files_still_generated
        ; Alcotest.test_case
            "has a real deploy target"
            `Quick
            test_scaffolded_workspace_has_a_real_deploy_target
        ; Alcotest.test_case
            "dune-project generated"
            `Quick
            test_workspace_has_dune_project
        ; Alcotest.test_case
            "Dockerfile paths relative"
            `Quick
            test_dockerfile_paths_are_workspace_relative
        ; Alcotest.test_case
            "README hints substituted"
            `Quick
            test_readme_migrate_hint_substituted
        ; Alcotest.test_case
            "framework dep declared, not vendored"
            `Quick
            test_framework_dependency_declared_not_vendored
        ; Alcotest.test_case "scaffold actually compiles" `Quick test_scaffold_compiles
        ; Alcotest.test_case
            "bare fn library compiles"
            `Quick
            test_bare_fn_library_compiles
        ; Alcotest.test_case
            "charge_svc publishes event"
            `Quick
            test_charge_svc_publishes_kafka_event
        ; Alcotest.test_case
            "JSON decoders are result based"
            `Quick
            test_workspace_generated_json_decoders_are_result_based
        ; Alcotest.test_case
            "startup helpers are flattened"
            `Quick
            test_workspace_startup_helpers_are_flattened
        ] )
    ; ( "worker_ack"
      , [ Alcotest.test_case
            "generated worker has no ack param"
            `Quick
            test_worker_has_no_ack_param
        ] )
    ; ( "domain_name_parser"
      , [ Alcotest.test_case
            "normalizes valid domain/name"
            `Quick
            test_parse_domain_name_normalizes_valid_name
        ; Alcotest.test_case
            "rejects malformed names"
            `Quick
            test_parse_domain_name_rejects_malformed_names
        ] )
    ; ( "bundle_resolution"
      , [ Alcotest.test_case
            "complete bundle layout resolves sol_home"
            `Quick
            test_bundle_layout_resolves_sol_home
        ; Alcotest.test_case
            "incomplete bundle is rejected"
            `Quick
            test_incomplete_bundle_rejected
        ; Alcotest.test_case
            "ancestor walk finds bundle root from bin/"
            `Quick
            test_ancestor_walk_finds_bundle_root
        ; Alcotest.test_case
            "ancestor walk skips _build context"
            `Quick
            test_ancestor_walk_skips_build_context
        ] )
    ; ( "pending_migrations"
      , [ Alcotest.test_case
            "no db/migrations dir → 0"
            `Quick
            test_pending_migrations_no_dir
        ; Alcotest.test_case
            "empty db/migrations dir → 0"
            `Quick
            test_pending_migrations_empty_dir
        ; Alcotest.test_case
            "counts only .sql files"
            `Quick
            test_pending_migrations_counts_sql_files
        ; Alcotest.test_case
            "a .down.sql reversal is not counted"
            `Quick
            test_pending_migrations_ignores_down_migrations
        ; Alcotest.test_case
            "scaffold workspace → 1 migration"
            `Quick
            test_pending_migrations_workspace_scaffold
        ] )
    ; ( "golden"
      , [ Alcotest.test_case "sol-ci.yml" `Quick test_golden_ci_workflow
        ; Alcotest.test_case "charge_svc Dockerfile" `Quick test_golden_dockerfile
        ; Alcotest.test_case "charge_svc bin/main.ml" `Quick test_golden_svc_bin_ml
        ; Alcotest.test_case "notify_worker bin/main.ml" `Quick test_golden_worker_bin_ml
        ; Alcotest.test_case "test/dune" `Quick test_golden_test_dune
        ; Alcotest.test_case "new svc files" `Quick test_golden_new_svc_files
        ; Alcotest.test_case "new worker files" `Quick test_golden_new_worker_files
        ; Alcotest.test_case "new fn files" `Quick test_golden_new_fn_files
        ] )
    ; ( "mkdir_p"
      , [ Alcotest.test_case
            "creates nested directories"
            `Quick
            test_mkdir_p_creates_nested_dirs
        ; Alcotest.test_case
            "tolerates an existing directory"
            `Quick
            test_mkdir_p_tolerates_existing_dir
        ; Alcotest.test_case
            "raises when a path component is a file"
            `Quick
            test_mkdir_p_raises_on_blocked_path
        ; Alcotest.test_case
            "raises on a broken symlink"
            `Quick
            test_mkdir_p_raises_on_broken_symlink
        ; Alcotest.test_case
            "tolerates a symlink to a real directory"
            `Quick
            test_mkdir_p_tolerates_symlink_to_real_directory
        ] )
    ]
;;
