(* Tests for Sol workspace scaffold (cmd_new.ml / sol new workspace).
   Calls new_workspace in a temp directory and asserts that the expected
   files are created with the correct content.  No build or cluster needed. *)

(* ── helpers ──────────────────────────────────────────────────────────────── *)

let check_bool = Alcotest.(check bool)

let contains haystack needle =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0
  then true
  else if nl > hl
  then false
  else (
    let found = ref false in
    for i = 0 to hl - nl do
      if (not !found) && String.sub haystack i nl = needle then found := true
    done;
    !found)
;;

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
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    f
;;

(* ── mkdir_p ──────────────────────────────────────────────────────────────── *)

(* Regression test: mkdir_p used to shell out to `mkdir -p` and discard the
   exit code, so a blocked path silently proceeded as if it had succeeded. *)
let test_mkdir_p_creates_nested_dirs () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_scaffold.mkdir_p "a/b/c";
  check_bool "nested directories created" true (Sys.is_directory "a/b/c")
;;

let test_mkdir_p_tolerates_existing_dir () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_scaffold.mkdir_p "a/b";
  Sol_cli_scaffold.mkdir_p "a/b" (* must not raise *)
;;

let test_mkdir_p_raises_on_blocked_path () =
  in_temp_dir
  @@ fun () ->
  let oc = open_out "blocker" in
  output_string oc "not a directory";
  close_out oc;
  match Sol_cli_scaffold.mkdir_p "blocker/child" with
  | () -> Alcotest.fail "expected mkdir_p to raise when a path component is a file"
  | exception Failure _ -> ()
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
  match Sol_cli_scaffold.mkdir_p "broken-link" with
  | () -> Alcotest.fail "expected mkdir_p to raise for a broken symlink"
  | exception Failure _ -> ()
;;

let test_mkdir_p_tolerates_symlink_to_real_directory () =
  in_temp_dir
  @@ fun () ->
  Unix.mkdir "real" 0o755;
  Unix.symlink "real" "link-to-real";
  Sol_cli_scaffold.mkdir_p "link-to-real" (* must not raise *)
;;

(* ── scaffold tests ───────────────────────────────────────────────────────── *)

(* Verify that sol-ci.yml is generated *)
let test_ci_workflow_created () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let path = "testapp/.github/workflows/sol-ci.yml" in
  check_bool "sol-ci.yml created" true (Sys.file_exists path)
;;

(* Verify that the existing deploy.yml is still generated *)
let test_deploy_workflow_created () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let path = "testapp/.github/workflows/deploy.yml" in
  check_bool "deploy.yml created" true (Sys.file_exists path)
;;

(* FEAT-026: deploy.yml's real (non-comment) `sol deploy` invocation passes
   a target via a SOL_TARGET repo variable, documented in the header. *)
let test_deploy_workflow_passes_target () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/deploy.yml" in
  assert_contains "deploy.yml" content "SOL_TARGET";
  assert_contains "deploy.yml" content "sol deploy \"$SOL_TARGET\""
;;

(* Verify that sol-ci.yml contains 'sol deploy' *)
let test_ci_contains_sol_deploy () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
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
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "SOL_TARGET";
  assert_contains "sol-ci.yml" content {|main.exe deploy "$SOL_TARGET"|}
;;

(* Verify that sol-ci.yml contains '--emit-plan-to' (FEAT-008 integration) *)
let test_ci_contains_emit_plan_to () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "--emit-plan-to"
;;

(* Verify that sol-ci.yml contains '--emit-to' (GitOps mode) *)
let test_ci_contains_emit_to () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "--emit-to"
;;

(* Verify that sol-ci.yml contains 'dune build' and 'dune runtest' *)
let test_ci_contains_dune_commands () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "dune build";
  assert_contains "sol-ci.yml" content "dune runtest"
;;

(* Verify no KUBECONFIG in the test/build job — cluster creds must stay out *)
let test_ci_no_kubeconfig_in_build_job () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  (* KUBECONFIG must not appear as a required secret or env var *)
  check_bool "no KUBECONFIG in sol-ci.yml" false (contains content "KUBECONFIG_B64")
;;

(* Verify that registry credentials are referenced as secrets (placeholders) *)
let test_ci_registry_secrets () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "secrets.REGISTRY";
  assert_contains "sol-ci.yml" content "secrets.REGISTRY_USER";
  assert_contains "sol-ci.yml" content "secrets.REGISTRY_PASSWORD"
;;

(* Verify that the CI contract comment block is present — PHASE 1 and PHASE 2 *)
let test_ci_contract_comment_present () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "Sol CI contract";
  assert_contains "sol-ci.yml" content "PHASE 1";
  assert_contains "sol-ci.yml" content "PHASE 2"
;;

(* Verify that the deploy phase comment names sol deploy as the typed contract *)
let test_ci_contract_deploy_phase_uses_sol_deploy () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
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
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  check_bool "no raw kubectl apply in sol-ci.yml" false (contains content "kubectl apply")
;;

(* Verify that the build-images step retains the TODO(sol-build) marker so
   future contributors know this step will be replaced by sol build *)
let test_ci_build_images_has_todo_sol_build () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sol-ci.yml" in
  assert_contains "sol-ci.yml" content "TODO(sol-build)"
;;

(* Verify that other expected workspace files are still present *)
let test_existing_files_still_generated () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let expected =
    [ "testapp/.ocamlformat"
    ; "testapp/.dockerignore"
    ; "testapp/dune-project"
    ; "testapp/README.md"
    ; "testapp/vendor/framework"
    ; "testapp/events/payments/charged.ml"
    ; "testapp/events/payments/dune"
    ; "testapp/lib/notification.ml"
    ; "testapp/app/payments/charge_svc/bin/main.ml"
    ; "testapp/app/payments/charge_svc/sol.toml"
    ; "testapp/app/comms/notify_worker/bin/main.ml"
    ; "testapp/app/comms/notify_worker/sol.toml"
    ; "testapp/db/migrations/0001_notifications.sql"
    ; "testapp/sol/prod/aws/us-east-1.yml"
    ]
  in
  List.iter
    (fun path -> check_bool (Printf.sprintf "%s exists" path) true (Sys.file_exists path))
    expected;
  (* quick count: at least 21 files *)
  let count = ref 0 in
  let rec walk dir =
    Array.iter
      (fun entry ->
         let full = Filename.concat dir entry in
         if full = "testapp/vendor"
         then ()
         else if Sys.is_directory full
         then walk full
         else incr count)
      (Sys.readdir dir)
  in
  walk "testapp";
  check_bool "at least 21 files generated" true (!count >= 21)
;;

(* FEAT-026 follow-up: `sol deploy` refuses to run against a target with no
   sol/<env>/<provider>/<region>.yml file, even an empty one (see
   cmd_deploy.ml's strict target-file check) -- a freshly scaffolded
   workspace must ship one so the acceptance criteria's own
   `sol deploy prod/aws/us-east-1 --dry-run` works with zero manual setup. *)
let test_scaffolded_workspace_has_a_real_deploy_target () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  Sys.chdir "testapp";
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Error e ->
    Alcotest.fail ("load_for_target failed: " ^ Sol_cli_config.error_to_string e)
  | Ok cfg ->
    (match Sol_cli_config.target cfg with
     | None -> Alcotest.fail "expected a resolved target"
     | Some target ->
       check_bool
         "sol/prod/aws/us-east-1.yml exists"
         true
         (Sys.file_exists (Sol_cli_config.target_file target)))
;;

let test_workspace_has_dune_project () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/dune-project" in
  assert_contains "dune-project" content "(lang dune 3.0)"
;;

let test_dockerfile_paths_are_workspace_relative () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
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
  Sol_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/README.md" in
  assert_contains "README" content "sol migrate";
  check_bool "README has no template placeholder" false (contains content "{{name}}")
;;

let test_sol_sources_linked () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  check_bool
    "framework source linked"
    true
    (Sys.file_exists "testapp/vendor/framework/sol-svc/lib/dune");
  check_bool
    "kafka-eio-service source linked"
    true
    (Sys.file_exists "testapp/vendor/framework/kafka-eio-service/lib/dune")
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
  Sol_cli_cmd_new.new_workspace "testapp";
  let rc = Sys.command "cd testapp && dune build 2>&1" in
  check_bool "freshly scaffolded workspace builds with `dune build`" true (rc = 0)
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
  Sol_cli_cmd_new.new_workspace "testapp";
  Sys.chdir "testapp";
  Sol_cli_cmd_new.new_fn "billing/invoice";
  let rc = Sys.command "dune build app/billing/invoice_fn/lib/ 2>&1" in
  Sys.chdir "..";
  check_bool "generic fn's own library target builds in isolation" true (rc = 0)
;;

let test_charge_svc_publishes_kafka_event () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
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
  Sol_cli_cmd_new.new_workspace "testapp";
  let event = read_file "testapp/events/payments/charged.ml" in
  let handler = read_file "testapp/app/payments/charge_svc/lib/handler.ml" in
  assert_contains "event" event "let required_string fields name";
  assert_contains "event" event "let required_int fields name";
  assert_contains "event" event "let ( let* ) = Result.bind";
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
  Sol_cli_cmd_new.new_workspace "testapp";
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
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
       (* Create the bundle directory structure *)
       let mkdir_p path =
         ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
       in
       mkdir_p (Filename.concat tmpdir "bin");
       mkdir_p (Filename.concat tmpdir "framework/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/kafka-eio-service/lib");
       (* Create the two sentinel dune files that is_sol_home checks *)
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       touch (Filename.concat tmpdir "framework/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/kafka-eio-service/lib/dune");
       (* Point SOL_HOME at the bundle root — infer_sol_home should accept it *)
       let result =
         let saved = Sys.getenv_opt "SOL_HOME" in
         Unix.putenv "SOL_HOME" tmpdir;
         let r = Sol_cli_cmd_new.infer_sol_home () in
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
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
       let mkdir_p path =
         ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
       in
       (* Only create the sol-svc sentinel, not the kafka-eio-service one *)
       mkdir_p (Filename.concat tmpdir "framework/sol-svc/lib");
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       touch (Filename.concat tmpdir "framework/sol-svc/lib/dune");
       (* SOL_HOME pointing here should be rejected — kafka-eio-service sentinel missing *)
       let result =
         let saved = Sys.getenv_opt "SOL_HOME" in
         Unix.putenv "SOL_HOME" tmpdir;
         let r = Sol_cli_cmd_new.infer_sol_home () in
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
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
       let mkdir_p path =
         ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
       in
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       (* Create the bundle layout: tmpdir/bin/, tmpdir/framework/... *)
       mkdir_p (Filename.concat tmpdir "bin");
       mkdir_p (Filename.concat tmpdir "framework/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/kafka-eio-service/lib");
       touch (Filename.concat tmpdir "framework/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/kafka-eio-service/lib/dune");
       (* is_sol_home should accept the bundle root *)
       check_bool
         "is_sol_home returns true for valid bundle root"
         true
         (Sol_cli_cmd_new.is_sol_home tmpdir);
       (* find_ancestor starting from the bin/ subdirectory should walk up to tmpdir *)
       let bin_dir = Filename.concat tmpdir "bin" in
       let result = Sol_cli_cmd_new.find_ancestor Sol_cli_cmd_new.is_sol_home bin_dir in
       check_bool "find_ancestor: returns Some" true (result <> None);
       check_bool
         "find_ancestor: resolved path matches bundle root"
         true
         (result = Some tmpdir))
;;

(* BUG-017: the ancestor walk must skip `_build/default` even when dune has
   mirrored the framework sentinel files there. If it did not, CLI tests run
   from `_build/default/cli/sol/test` would resolve SOL_HOME to the build tree
   and fail against missing source-side files/artifacts. *)
let test_ancestor_walk_skips_build_context () =
  let tmpdir = Filename.temp_file "sol-build-context-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
       let mkdir_p path =
         ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
       in
       let touch path =
         let oc = open_out path in
         close_out oc
       in
       (* A real source/release root: tmpdir/framework/... *)
       mkdir_p (Filename.concat tmpdir "framework/sol-svc/lib");
       mkdir_p (Filename.concat tmpdir "framework/kafka-eio-service/lib");
       touch (Filename.concat tmpdir "framework/sol-svc/lib/dune");
       touch (Filename.concat tmpdir "framework/kafka-eio-service/lib/dune");
       (* The misleading build context: tmpdir/_build/default/framework/... *)
       let build_default = Filename.concat tmpdir "_build/default" in
       mkdir_p (Filename.concat build_default "framework/sol-svc/lib");
       mkdir_p (Filename.concat build_default "framework/kafka-eio-service/lib");
       touch (Filename.concat build_default "framework/sol-svc/lib/dune");
       touch (Filename.concat build_default "framework/kafka-eio-service/lib/dune");
       check_bool
         "is_sol_home rejects _build/default"
         false
         (Sol_cli_cmd_new.is_sol_home build_default);
       (* Walk from a simulated test executable under the build context. *)
       let start = Filename.concat build_default "cli/sol/test" in
       let result = Sol_cli_cmd_new.find_ancestor Sol_cli_cmd_new.is_sol_home start in
       check_bool "ancestor walk skips _build/default" true (result = Some tmpdir))
;;

(* The framework acknowledges automatically after handle returns Ok (); a
   generated worker must have no ~ack param to call, misorder, or forget. *)
let test_worker_has_no_ack_param () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_worker "comms/notify";
  let lib = read_file "app/comms/notify_worker/lib/notify_worker.ml" in
  check_bool "generated worker does not reference ~ack" false (contains lib "~ack");
  assert_contains "worker lib" lib "~trace_ctx";
  assert_contains "worker lib" lib "Printf.printf";
  assert_contains "worker lib" lib "Ok ()"
;;

(* ── pending_migration_count tests ──────────────────────────────────────── *)

(* No db/migrations directory → count is 0 *)
let test_pending_migrations_no_dir () =
  let tmpdir = Filename.temp_file "sol-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
       check_bool
         "no mig dir → 0"
         true
         (Sol_cli_workspace.pending_migration_count ~dir:tmpdir = 0))
;;

(* db/migrations exists but is empty → count is 0 *)
let test_pending_migrations_empty_dir () =
  let tmpdir = Filename.temp_file "sol-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
       ignore
         (Sys.command
            (Printf.sprintf "mkdir -p %s/db/migrations" (Filename.quote tmpdir)));
       check_bool
         "empty dir → 0"
         true
         (Sol_cli_workspace.pending_migration_count ~dir:tmpdir = 0))
;;

(* db/migrations with two .sql files → count is 2 *)
let test_pending_migrations_counts_sql_files () =
  let tmpdir = Filename.temp_file "sol-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
       ignore
         (Sys.command
            (Printf.sprintf "mkdir -p %s/db/migrations" (Filename.quote tmpdir)));
       let touch name =
         let path = Printf.sprintf "%s/db/migrations/%s" tmpdir name in
         let oc = open_out path in
         close_out oc
       in
       touch "0001_init.sql";
       touch "0002_add_column.sql";
       touch "README.md";
       (* non-.sql — must not be counted *)
       check_bool
         "two sql files → 2"
         true
         (Sol_cli_workspace.pending_migration_count ~dir:tmpdir = 2))
;;

(* workspace scaffold generates one .sql file → count is 1 *)
let test_pending_migrations_workspace_scaffold () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  check_bool
    "scaffold workspace → 1 migration file"
    true
    (Sol_cli_workspace.pending_migration_count ~dir:"testapp" = 1)
;;

(* ── golden tests ────────────────────────────────────────────────────────── *)

(* Golden: sol-ci.yml is byte-for-byte equivalent to the template source after
   substitution of {{name}}.  Any change to the template is visible in this diff. *)
let test_golden_ci_workflow () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let actual = read_file "testapp/.github/workflows/sol-ci.yml" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"; "Name", "Testapp" ]
      Sol_cli_scaffold_templates.tpl_github_ci
  in
  Alcotest.(check string) "sol-ci.yml golden" expected actual
;;

(* Golden: charge_svc Dockerfile is byte-for-byte equivalent. *)
let test_golden_dockerfile () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let actual = read_file "testapp/app/payments/charge_svc/Dockerfile" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"
      ; "Name", "Testapp"
      ; "repo_dir", "app/payments/charge_svc"
      ; "binary", "testapp-charge-svc"
      ]
      Sol_cli_scaffold_templates.tpl_dockerfile
  in
  Alcotest.(check string) "Dockerfile golden" expected actual
;;

(* Golden: charge_svc bin/main.ml *)
let test_golden_svc_bin_ml () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let actual = read_file "testapp/app/payments/charge_svc/bin/main.ml" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"; "Name", "Testapp" ]
      Sol_cli_scaffold_templates.ws_svc_bin_ml
  in
  Alcotest.(check string) "svc bin/main.ml golden" expected actual
;;

(* Golden: notify_worker bin/main.ml *)
let test_golden_worker_bin_ml () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let actual = read_file "testapp/app/comms/notify_worker/bin/main.ml" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"; "Name", "Testapp" ]
      Sol_cli_scaffold_templates.ws_worker_bin_ml
  in
  Alcotest.(check string) "worker bin/main.ml golden" expected actual
;;

(* Golden: test/dune — exact content check so scaffold schema-test regressions
   show up as a readable diff rather than a silent missing-file failure. *)
let test_golden_test_dune () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_workspace "testapp";
  let actual = read_file "testapp/test/dune" in
  let expected =
    Sol_cli_scaffold.subst
      [ "name", "testapp"; "Name", "Testapp" ]
      Sol_cli_scaffold_templates.ws_test_dune
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
  ]
;;

let check_generated_file label path expected =
  let actual = read_file path in
  Alcotest.(check string) label expected actual
;;

let test_golden_new_svc_files () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_svc "comms/notify";
  let v = component_vars ~suffix:"svc" ~mod_:"Handler" in
  check_generated_file
    "svc handler"
    "app/comms/notify_svc/lib/handler.ml"
    Sol_cli_scaffold_templates.svc_handler_ml;
  check_generated_file
    "svc lib dune"
    "app/comms/notify_svc/lib/dune"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.svc_lib_dune);
  check_generated_file
    "svc bin main"
    "app/comms/notify_svc/bin/main.ml"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.svc_bin_ml);
  check_generated_file
    "svc bin dune"
    "app/comms/notify_svc/bin/dune"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.svc_bin_dune);
  check_generated_file
    "svc sol.toml"
    "app/comms/notify_svc/sol.toml"
    Sol_cli_scaffold_templates.tpl_sol_toml;
  check_generated_file
    "svc Dockerfile"
    "app/comms/notify_svc/Dockerfile"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.tpl_dockerfile)
;;

let test_golden_new_worker_files () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_worker "comms/notify";
  let v = component_vars ~suffix:"worker" ~mod_:"Notify_worker" in
  check_generated_file
    "worker lib"
    "app/comms/notify_worker/lib/notify_worker.ml"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.worker_lib_ml);
  check_generated_file
    "worker lib dune"
    "app/comms/notify_worker/lib/dune"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.worker_lib_dune);
  check_generated_file
    "worker bin main"
    "app/comms/notify_worker/bin/main.ml"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.worker_bin_ml);
  check_generated_file
    "worker bin dune"
    "app/comms/notify_worker/bin/dune"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.worker_bin_dune);
  check_generated_file
    "worker sol.toml"
    "app/comms/notify_worker/sol.toml"
    Sol_cli_scaffold_templates.tpl_sol_toml;
  check_generated_file
    "worker Dockerfile"
    "app/comms/notify_worker/Dockerfile"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.tpl_dockerfile)
;;

let test_golden_new_fn_files () =
  in_temp_dir
  @@ fun () ->
  Sol_cli_cmd_new.new_fn "comms/notify";
  let v = component_vars ~suffix:"fn" ~mod_:"Notify_fn" in
  check_generated_file
    "fn lib"
    "app/comms/notify_fn/lib/notify_fn.ml"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.fn_lib_ml);
  check_generated_file
    "fn lib dune"
    "app/comms/notify_fn/lib/dune"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.fn_lib_dune);
  check_generated_file
    "fn bin main"
    "app/comms/notify_fn/bin/main.ml"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.fn_bin_ml);
  check_generated_file
    "fn bin dune"
    "app/comms/notify_fn/bin/dune"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.fn_bin_dune);
  check_generated_file
    "fn sol.toml"
    "app/comms/notify_fn/sol.toml"
    Sol_cli_scaffold_templates.tpl_fn_sol_toml;
  check_generated_file
    "fn Dockerfile"
    "app/comms/notify_fn/Dockerfile"
    (Sol_cli_scaffold.subst v Sol_cli_scaffold_templates.tpl_dockerfile)
;;

(* ── entry point ─────────────────────────────────────────────────────────── *)

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
        ; Alcotest.test_case "Sol sources linked" `Quick test_sol_sources_linked
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
