let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let check_strings msg expected actual =
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg expected actual
;;

let write_file path content =
  let rec mkdirs path =
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent)
    then (
      mkdirs parent;
      Unix.mkdir parent 0o755)
  in
  mkdirs path;
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_workspace files f =
  let root = Filename.temp_file "sol-local-run-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  write_file (Filename.concat root "sol.yml") "";
  List.iter (fun (rel, content) -> write_file (Filename.concat root rel) content) files;
  Fun.protect ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root)) (fun () -> f root)
;;

let facts_of root =
  match Sol_cli_workspace_model.load ~root with
  | Ok facts -> facts
  | Error e -> Windtrap.fail ("workspace model failed to load: " ^ e)
;;

let services_of facts = Sol_cli_workspace_model.services facts
let sol_yml ~services = services
let dockerfile = "FROM scratch\n"

let test_ocaml_unit_builds_with_dune_and_runs_the_binary () =
  with_workspace
    [ "sol.yml", sol_yml ~services:"services:\n  charge_svc:\n    language: ocaml\n"
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ; "app/payments/charge_svc/bin/dune", "(executable (name main))\n"
    ]
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.builds with
     | [ build ] ->
       check_strings
         "one merged dune build"
         [ "dune"; "build"; "app/payments/charge_svc/bin/main.exe" ]
         build.argv;
       check_string "in the workspace root" "" build.cwd
     | builds ->
       Windtrap.fail (Printf.sprintf "expected one build, got %d" (List.length builds)));
    (match plan.launches with
     | [ launch ] ->
       check_strings
         "launches the compiled binary"
         [ "_build/default/app/payments/charge_svc/bin/main.exe" ]
         launch.launch.argv;
       check_string "artifact" "app/payments/charge_svc/bin/main.exe" launch.artifact;
       check_bool "declared OCaml" true (launch.language = Sol_cli_compat.Ocaml);
       check_string
         "carries the injected workspace identity"
         (Filename.basename root)
         (Option.value ~default:"" (List.assoc_opt "SOL_WORKSPACE" launch.env));
       check_string
         "carries the injected domain identity"
         "payments"
         (Option.value ~default:"" (List.assoc_opt "SOL_DOMAIN" launch.env));
       check_string
         "carries the bare Kubernetes service name"
         "charge-svc"
         (Option.value ~default:"" (List.assoc_opt "SOL_SERVICE" launch.env));
       check_string
         "carries the primitive"
         "svc"
         (Option.value ~default:"" (List.assoc_opt "SOL_PRIMITIVE" launch.env));
       check_bool "keeps the dev addresses" true (List.mem_assoc "LOKI_URL" launch.env);
       check_bool
         "omits env locally by design"
         false
         (List.mem_assoc "SOL_ENV" launch.env)
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let typescript_unit =
  [ ( "app/demo_ts/package.json"
    , {|{"name": "demo-ts", "private": true, "workspaces": ["order_svc", "fulfillment_worker"]}|}
    )
  ; "app/demo_ts/node_modules/.keep", ""
  ; ( "app/demo_ts/order_svc/package.json"
    , {|{"name": "order-svc", "scripts": {"build": "tsc", "start": "node dist/index.js"}}|}
    )
  ; ( "app/demo_ts/order_svc/tsconfig.json"
    , {|{"compilerOptions": {"outDir": "dist", "rootDir": "src"}}|} )
  ; "app/demo_ts/order_svc/Dockerfile", dockerfile
  ; "app/demo_ts/order_svc/sol.toml", ""
  ]
;;

let ts_workspace =
  ("sol.yml", "services:\n  order_svc:\n    language: typescript\n") :: typescript_unit
;;

let test_typescript_unit_builds_through_npm_and_runs_node () =
  with_workspace ts_workspace
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.builds with
     | [ build ] ->
       check_strings
         "builds the npm workspace by package name"
         [ "npm"; "run"; "build"; "--workspace"; "order-svc" ]
         build.argv;
       check_string "in the npm project root" "app/demo_ts" build.cwd
     | builds ->
       Windtrap.fail (Printf.sprintf "expected one build, got %d" (List.length builds)));
    (match plan.launches with
     | [ launch ] ->
       check_strings
         "runs the built entry directly with node"
         [ "node"; "order_svc/dist/index.js" ]
         launch.launch.argv;
       check_string "in the npm project root" "app/demo_ts" launch.launch.cwd;
       check_string "artifact" "app/demo_ts/order_svc/dist/index.js" launch.artifact;
       check_bool "declared TypeScript" true (launch.language = Sol_cli_compat.Typescript)
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let test_a_standalone_typescript_unit_is_its_own_project () =
  with_workspace
    [ "sol.yml", "services:\n  api_svc:\n    language: typescript\n"
    ; "app/api/api_svc/package.json", {|{"name": "api", "scripts": {"build": "tsc"}}|}
    ; "app/api/api_svc/tsconfig.json", {|{"compilerOptions": {"outDir": "build"}}|}
    ; "app/api/api_svc/node_modules/.keep", ""
    ; "app/api/api_svc/Dockerfile", dockerfile
    ; "app/api/api_svc/sol.toml", ""
    ]
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.builds with
     | [ build ] ->
       check_strings "no workspace selector" [ "npm"; "run"; "build" ] build.argv;
       check_string "built in the unit" "app/api/api_svc" build.cwd
     | builds ->
       Windtrap.fail (Printf.sprintf "expected one build, got %d" (List.length builds)));
    (match plan.launches with
     | [ launch ] ->
       check_strings
         "the tsconfig outDir is honoured"
         [ "node"; "build/index.js" ]
         launch.launch.argv
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let build_of root =
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.builds with
     | [ build ] -> build
     | builds ->
       Windtrap.fail (Printf.sprintf "expected one build, got %d" (List.length builds)))
;;

let api_unit_package_json = {|{"name": "api", "scripts": {"build": "tsc"}}|}
let api_unit_tsconfig = {|{"compilerOptions": {"outDir": "build"}}|}

let api_svc_workspace ~root_package_json =
  [ "sol.yml", "services:\n  api_svc:\n    language: typescript\n"
  ; "app/package.json", root_package_json
  ; "app/node_modules/.keep", ""
  ; "app/api/api_svc/package.json", api_unit_package_json
  ; "app/api/api_svc/tsconfig.json", api_unit_tsconfig
  ; "app/api/api_svc/node_modules/.keep", ""
  ; "app/api/api_svc/Dockerfile", dockerfile
  ; "app/api/api_svc/sol.toml", ""
  ]
;;

let test_an_unrelated_glob_does_not_capture_a_unit () =
  with_workspace
    (api_svc_workspace
       ~root_package_json:
         {|{"name": "app-root", "private": true, "workspaces": ["tools/*"]}|})
  @@ fun root ->
  let build = build_of root in
  check_strings
    "tools/* does not capture app/api/api_svc"
    [ "npm"; "run"; "build" ]
    build.argv;
  check_string "built as its own project" "app/api/api_svc" build.cwd
;;

let test_a_nested_exact_entry_selects_the_ancestor () =
  with_workspace
    (api_svc_workspace
       ~root_package_json:
         {|{"name": "app-root", "private": true, "workspaces": ["api/api_svc"]}|})
  @@ fun root ->
  let build = build_of root in
  check_strings
    "the nested exact entry selects the workspace"
    [ "npm"; "run"; "build"; "--workspace"; "api" ]
    build.argv;
  check_string "built in the npm project root" "app" build.cwd
;;

let test_a_supported_glob_selects_the_ancestor () =
  with_workspace
    (api_svc_workspace
       ~root_package_json:
         {|{"name": "app-root", "private": true, "workspaces": ["api/*", "tools/*"]}|})
  @@ fun root ->
  let build = build_of root in
  check_strings
    "api/* matches the single-segment package directory"
    [ "npm"; "run"; "build"; "--workspace"; "api" ]
    build.argv;
  check_string "built in the npm project root" "app" build.cwd
;;

let test_a_glob_does_not_cross_path_segments () =
  with_workspace
    (api_svc_workspace
       ~root_package_json:
         {|{"name": "app-root", "private": true, "workspaces": ["app/*", "tools/*"]}|})
  @@ fun root ->
  let build = build_of root in
  check_strings
    "app/* does not reach app/api/api_svc"
    [ "npm"; "run"; "build" ]
    build.argv;
  check_string "built as its own project" "app/api/api_svc" build.cwd
;;

let test_a_mixed_selection_uses_both_adapters () =
  let files =
    [ ( "sol.yml"
      , "services:\n\
        \  charge_svc:\n\
        \    language: ocaml\n\
        \  order_svc:\n\
        \    language: typescript\n" )
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ]
    @ typescript_unit
  in
  with_workspace files
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    check_bool "two units" true (List.length plan.launches = 2);
    (match plan.builds with
     | [ dune_build; npm_build ] ->
       check_strings
         "the dune build covers only the OCaml unit"
         [ "dune"; "build"; "app/payments/charge_svc/bin/main.exe" ]
         dune_build.argv;
       check_strings
         "the TypeScript unit builds with npm"
         [ "npm"; "run"; "build"; "--workspace"; "order-svc" ]
         npm_build.argv
     | builds ->
       Windtrap.fail (Printf.sprintf "expected two builds, got %d" (List.length builds)));
    let services = services_of facts in
    check_strings
      "both units are launched, in selection order"
      (List.map Sol_cli_local_run.label services)
      (List.map (fun (r : Sol_cli_local_run.recipe) -> r.label) plan.launches)
;;

let expect_error ~needle = function
  | Ok _ -> Windtrap.fail "expected the plan to refuse"
  | Error errors ->
    let messages = List.map (fun (label, message) -> label ^ " " ^ message) errors in
    check_bool
      (Printf.sprintf "names %S in %s" needle (String.concat "; " messages))
      true
      (List.exists (fun message -> Sol_cli_string.contains ~needle message) messages)
;;

let test_an_undeclared_workload_is_refused () =
  with_workspace
    [ "sol.yml", ""
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ]
  @@ fun root ->
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
  |> expect_error ~needle:"declares no language"
;;

let test_a_typescript_unit_without_a_package_is_refused () =
  with_workspace
    [ "sol.yml", "services:\n  charge_svc:\n    language: typescript\n"
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ]
  @@ fun root ->
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
  |> expect_error ~needle:"package.json could not be read"
;;

let test_typescript_dependencies_that_are_not_installed_are_refused () =
  let files =
    List.filter
      (fun (rel, _) -> not (String.equal rel "app/demo_ts/node_modules/.keep"))
      ts_workspace
  in
  with_workspace files
  @@ fun root ->
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
  |> expect_error ~needle:"run `npm ci` in app/demo_ts"
;;

let test_one_bad_unit_refuses_the_whole_plan () =
  with_workspace
    [ ( "sol.yml"
      , "services:\n\
        \  charge_svc:\n\
        \    language: ocaml\n\
        \  ledger_worker:\n\
        \    language: ocaml\n" )
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ; "app/comms/ledger_worker/Dockerfile", dockerfile
    ; "app/comms/ledger_worker/sol.toml", ""
    ]
  @@ fun root ->
  write_file
    (Filename.concat root "sol.yml")
    "services:\n  charge_svc:\n    language: ocaml\n";
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
  |> expect_error ~needle:"ledger_worker declares no language"
;;

let test_shell_lines () =
  let command argv cwd = { Sol_cli_local_run.argv; cwd } in
  Windtrap.equal
    Windtrap.string
    ~msg:"a root build, under the opam env"
    "eval $(opam env 2>/dev/null) 2>/dev/null; 'dune' 'build' './a b.exe'"
    (Sol_cli_local_run.build_line (command [ "dune"; "build"; "./a b.exe" ] ""));
  Windtrap.equal
    Windtrap.string
    ~msg:"a build in its npm project"
    "eval $(opam env 2>/dev/null) 2>/dev/null; cd 'app/x' && 'npm' 'run' 'build'"
    (Sol_cli_local_run.build_line (command [ "npm"; "run"; "build" ] "app/x"));
  Windtrap.equal
    Windtrap.string
    ~msg:"a launch"
    "'node' 'dist/main.js'"
    (Sol_cli_local_run.launch_line (command [ "node"; "dist/main.js" ] "."))
;;

let index_of haystack needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length haystack
    then None
    else if String.sub haystack i n = needle
    then Some i
    else go (i + 1)
  in
  go 0
;;

let test_command_preserves_build_launch_phases () =
  let sol = Cli_binary.path () in
  let check build_exit expected_phases expected_success =
    with_workspace ts_workspace (fun root ->
      let bin = Filename.concat root "fake-bin" in
      let log = Filename.concat root "phases" in
      let npm = Filename.concat bin "npm" in
      let node = Filename.concat bin "node" in
      write_file
        npm
        "#!/bin/sh\n\
         echo build >> \"$SOL_TEST_PHASE_LOG\"\n\
         exit \"$SOL_TEST_BUILD_EXIT\"\n";
      write_file
        node
        "#!/bin/sh\necho launch >> \"$SOL_TEST_PHASE_LOG\"\necho child-output\n";
      Unix.chmod npm 0o755;
      Unix.chmod node 0o755;
      let path = bin ^ ":" ^ Option.value (Sys.getenv_opt "PATH") ~default:"" in
      let result =
        Sol_cli_process.run
          ~echo:false
          (Sol_cli_process.cmd
             ~timeout_s:10.
             ~env:
               [ "PATH", path
               ; "SOL_TEST_PHASE_LOG", log
               ; "SOL_TEST_BUILD_EXIT", string_of_int build_exit
               ]
             [ sol; "local"; "run"; "--workspace"; root ])
      in
      check_bool "command success" expected_success (Result.is_ok result);
      let phases = In_channel.with_open_text log In_channel.input_all in
      check_string "build gates launch" expected_phases phases;
      let stdout =
        match result with
        | Ok completed -> completed.stdout
        | Error (Sol_cli_process.Non_zero failure) -> failure.stdout
        | Error _ -> ""
      in
      let precedes before after =
        match index_of stdout before, index_of stdout after with
        | Some i, Some j -> i < j
        | _ -> false
      in
      check_bool
        "the plan report precedes the build"
        true
        (precedes "Starting 1 service(s)" "Building...");
      check_bool
        "Build done. is reported only on success"
        expected_success
        (Option.is_some (index_of stdout "Build done."));
      check_bool
        "the build precedes the launch"
        expected_success
        (precedes "Building..." "Services running"))
  in
  check 0 "build\nlaunch\n" true;
  check 7 "build\n" false
;;

let%test "adapters: an OCaml unit builds with dune and runs the binary" =
  test_ocaml_unit_builds_with_dune_and_runs_the_binary ()
;;

let%test "adapters: a TypeScript unit builds through npm and runs node" =
  test_typescript_unit_builds_through_npm_and_runs_node ()
;;

let%test "adapters: a standalone TypeScript unit is its own project" =
  test_a_standalone_typescript_unit_is_its_own_project ()
;;

let%test "adapters: a mixed selection uses both adapters" =
  test_a_mixed_selection_uses_both_adapters ()
;;

let%test "adapters: an unrelated glob does not capture a unit (BUG-076)" =
  test_an_unrelated_glob_does_not_capture_a_unit ()
;;

let%test "adapters: a nested exact entry selects the ancestor (BUG-076)" =
  test_a_nested_exact_entry_selects_the_ancestor ()
;;

let%test "adapters: a supported glob selects the ancestor (BUG-076)" =
  test_a_supported_glob_selects_the_ancestor ()
;;

let%test "adapters: a glob does not cross path segments (BUG-076)" =
  test_a_glob_does_not_cross_path_segments ()
;;

let%test "adapters: build and launch" = test_shell_lines ()

let%test "command phases: build gates launch" =
  test_command_preserves_build_launch_phases ()
;;

let%test "refusals: an undeclared workload" = test_an_undeclared_workload_is_refused ()

let%test "refusals: a TypeScript unit with no package.json" =
  test_a_typescript_unit_without_a_package_is_refused ()
;;

let%test "refusals: TypeScript dependencies that are not installed" =
  test_typescript_dependencies_that_are_not_installed_are_refused ()
;;

let%test "refusals: one undrivable unit refuses the whole plan" =
  test_one_bad_unit_refuses_the_whole_plan ()
;;

let standalone_ts_unit ~package_json ?tsconfig () =
  [ "sol.yml", "services:\n  api_svc:\n    language: typescript\n"
  ; "app/api/api_svc/package.json", package_json
  ; "app/api/api_svc/node_modules/.keep", ""
  ; "app/api/api_svc/Dockerfile", dockerfile
  ; "app/api/api_svc/sol.toml", ""
  ]
  @
  match tsconfig with
  | None -> []
  | Some content -> [ "app/api/api_svc/tsconfig.json", content ]
;;

let plan_of root =
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
;;

let test_an_absent_tsconfig_keeps_the_documented_default () =
  with_workspace (standalone_ts_unit ~package_json:{|{"name": "api"}|} ())
  @@ fun root ->
  match plan_of root with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.launches with
     | [ launch ] ->
       check_strings "the dist default" [ "node"; "dist/index.js" ] launch.launch.argv;
       check_string "artifact under dist" "app/api/api_svc/dist/index.js" launch.artifact
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let%test "metadata: an absent tsconfig keeps the dist default" =
  test_an_absent_tsconfig_keeps_the_documented_default ()
;;

let test_a_malformed_tsconfig_is_refused () =
  with_workspace
    (standalone_ts_unit ~package_json:{|{"name": "api"}|} ~tsconfig:"{ not json" ())
  @@ fun root -> plan_of root |> expect_error ~needle:"tsconfig.json"
;;

let%test "metadata: a malformed tsconfig is refused" =
  test_a_malformed_tsconfig_is_refused ()
;;

let test_an_unreadable_tsconfig_is_refused () =
  if Unix.geteuid () = 0
  then ()
  else
    with_workspace
      (standalone_ts_unit ~package_json:{|{"name": "api"}|} ~tsconfig:"{}" ())
    @@ fun root ->
    let path = Filename.concat root "app/api/api_svc/tsconfig.json" in
    Unix.chmod path 0o000;
    let result =
      Fun.protect (fun () -> plan_of root) ~finally:(fun () -> Unix.chmod path 0o644)
    in
    result |> expect_error ~needle:"tsconfig.json"
;;

let%test "metadata: an unreadable tsconfig is refused" =
  test_an_unreadable_tsconfig_is_refused ()
;;

let test_an_outdir_of_the_wrong_type_is_refused () =
  with_workspace
    (standalone_ts_unit
       ~package_json:{|{"name": "api"}|}
       ~tsconfig:{|{"compilerOptions": {"outDir": 5}}|}
       ())
  @@ fun root ->
  plan_of root |> expect_error ~needle:"compilerOptions.outDir must be text"
;;

let%test "metadata: a non-text outDir is refused" =
  test_an_outdir_of_the_wrong_type_is_refused ()
;;

let test_compiler_options_of_the_wrong_type_is_refused () =
  with_workspace
    (standalone_ts_unit
       ~package_json:{|{"name": "api"}|}
       ~tsconfig:{|{"compilerOptions": "nope"}|}
       ())
  @@ fun root -> plan_of root |> expect_error ~needle:"compilerOptions must be an object"
;;

let%test "metadata: non-object compilerOptions is refused" =
  test_compiler_options_of_the_wrong_type_is_refused ()
;;

let test_a_non_text_main_is_refused () =
  with_workspace (standalone_ts_unit ~package_json:{|{"name": "api", "main": 123}|} ())
  @@ fun root -> plan_of root |> expect_error ~needle:"main must be text"
;;

let%test "metadata: a non-text main is refused" = test_a_non_text_main_is_refused ()

let test_a_malformed_ancestor_package_is_refused () =
  with_workspace (api_svc_workspace ~root_package_json:"{ not json")
  @@ fun root -> plan_of root |> expect_error ~needle:"app/package.json"
;;

let%test "metadata: a malformed ancestor package.json is refused" =
  test_a_malformed_ancestor_package_is_refused ()
;;

let test_malformed_workspaces_is_refused () =
  with_workspace
    (api_svc_workspace ~root_package_json:{|{"name": "app-root", "workspaces": "api/*"}|})
  @@ fun root ->
  plan_of root |> expect_error ~needle:"workspaces must be a list of strings"
;;

let%test "metadata: a non-list workspaces field is refused" =
  test_malformed_workspaces_is_refused ()
;;

let test_workspaces_with_non_string_entries_is_refused () =
  with_workspace
    (api_svc_workspace ~root_package_json:{|{"name": "app-root", "workspaces": [1, 2]}|})
  @@ fun root ->
  plan_of root |> expect_error ~needle:"workspaces must be a list of strings"
;;

let%test "metadata: non-string workspaces entries are refused" =
  test_workspaces_with_non_string_entries_is_refused ()
;;
