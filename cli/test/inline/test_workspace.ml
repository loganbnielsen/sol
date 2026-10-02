let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_tmpdir f =
  let tmpdir = Filename.temp_file "sol-workspace-root-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree tmpdir))
    (fun () -> f tmpdir)
;;

let test_workspace_without_dune_marker () =
  with_tmpdir (fun tmpdir ->
    write_file (Filename.concat tmpdir "sol.yml") "";
    mkdir_p (Filename.concat tmpdir "app/payments/charge_svc");
    check_bool
      "sol.yml alone resolves the root"
      true
      (Sol_cli_workspace.find_root ~dir:tmpdir = Some tmpdir))
;;

let test_nested_in_ocaml_repo () =
  with_tmpdir (fun tmpdir ->
    let child = Filename.concat tmpdir "child" in
    mkdir_p child;
    write_file (Filename.concat tmpdir "dune-project") "(lang dune 3.0)\n";
    write_file (Filename.concat child "sol.yml") "";
    check_bool
      "the nearer sol.yml wins over the enclosing dune-project"
      true
      (Sol_cli_workspace.find_root ~dir:child = Some child))
;;

let test_nested_in_node_repo () =
  with_tmpdir (fun tmpdir ->
    let child = Filename.concat tmpdir "child" in
    mkdir_p child;
    write_file (Filename.concat tmpdir "package.json") "{\"name\":\"parent\"}\n";
    write_file (Filename.concat child "sol.yml") "";
    check_bool
      "the nearer sol.yml wins over the enclosing package.json"
      true
      (Sol_cli_workspace.find_root ~dir:child = Some child))
;;

let test_mixed_ocaml_and_typescript_workspace () =
  with_tmpdir (fun tmpdir ->
    write_file (Filename.concat tmpdir "sol.yml") "";
    let ocaml_unit = Filename.concat tmpdir "app/payments/charge_svc" in
    let ts_unit = Filename.concat tmpdir "app/comms/notify_ts" in
    mkdir_p ocaml_unit;
    mkdir_p ts_unit;
    write_file (Filename.concat tmpdir "dune-project") "(lang dune 3.0)\n";
    write_file (Filename.concat ocaml_unit "dune") "(executable (name main))\n";
    write_file (Filename.concat ts_unit "package.json") "{\"name\":\"notify\"}\n";
    check_bool
      "OCaml unit resolves to the common Sol root"
      true
      (Sol_cli_workspace.find_root ~dir:ocaml_unit = Some tmpdir);
    check_bool
      "TS unit resolves to the same common Sol root"
      true
      (Sol_cli_workspace.find_root ~dir:ts_unit = Some tmpdir))
;;

let test_descendant_cwd_resolves_root () =
  with_tmpdir (fun tmpdir ->
    write_file (Filename.concat tmpdir "sol.yml") "";
    let nested = Filename.concat tmpdir "app/payments/charge_svc/lib" in
    mkdir_p nested;
    check_bool
      "a deep descendant walks up to the workspace root"
      true
      (Sol_cli_workspace.find_root ~dir:nested = Some tmpdir))
;;

let test_sibling_workspaces_resolve_independently () =
  with_tmpdir (fun tmpdir ->
    let a = Filename.concat tmpdir "product-a"
    and b = Filename.concat tmpdir "product-b" in
    mkdir_p a;
    mkdir_p b;
    write_file (Filename.concat a "sol.yml") "";
    write_file (Filename.concat b "sol.yml") "";
    check_bool
      "sibling a resolves to itself"
      true
      (Sol_cli_workspace.find_root ~dir:a = Some a);
    check_bool
      "sibling b resolves to itself"
      true
      (Sol_cli_workspace.find_root ~dir:b = Some b))
;;

let test_nested_workspace_is_rejected () =
  with_tmpdir (fun tmpdir ->
    let outer = Filename.concat tmpdir "product"
    and inner = Filename.concat tmpdir "product/foo" in
    mkdir_p inner;
    write_file (Filename.concat outer "sol.yml") "";
    write_file (Filename.concat inner "sol.yml") "";
    (match Sol_cli_workspace.validate ~root:outer with
     | Ok () -> Windtrap.fail "expected the nested boundary to be rejected"
     | Error (Sol_cli_workspace.Nested_workspace { outer = o; inner = i }) ->
       check_string "outer boundary" outer o;
       check_string "inner boundary" inner i
     | Error Sol_cli_workspace.Not_in_workspace ->
       Windtrap.fail "expected Nested_workspace, got Not_in_workspace");
    match Sol_cli_workspace.resolve_validated ~dir:outer with
    | Ok _ -> Windtrap.fail "expected resolve_validated to reject nesting"
    | Error (Sol_cli_workspace.Nested_workspace _) -> ()
    | Error Sol_cli_workspace.Not_in_workspace ->
      Windtrap.fail "expected Nested_workspace, got Not_in_workspace")
;;

let test_absence_fails_closed_with_guidance () =
  with_tmpdir (fun tmpdir ->
    mkdir_p (Filename.concat tmpdir "app/payments/charge_svc");
    write_file (Filename.concat tmpdir "dune-project") "(lang dune 3.0)\n";
    check_bool
      "no sol.yml -> find_root returns None"
      true
      (Sol_cli_workspace.find_root ~dir:tmpdir = None);
    match Sol_cli_workspace.resolve ~dir:tmpdir with
    | Ok _ -> Windtrap.fail "expected absence to fail closed"
    | Error Sol_cli_workspace.Not_in_workspace ->
      let message =
        Sol_cli_workspace.workspace_error_to_string Sol_cli_workspace.Not_in_workspace
      in
      check_bool
        "the error names `sol new workspace`"
        true
        (Sol_cli_string.contains ~needle:"sol new workspace" message)
    | Error (Sol_cli_workspace.Nested_workspace _) ->
      Windtrap.fail "expected Not_in_workspace")
;;

let test_sol_yml_must_be_a_file () =
  with_tmpdir (fun tmpdir ->
    Unix.mkdir (Filename.concat tmpdir "sol.yml") 0o755;
    check_bool
      "a directory named sol.yml does not count"
      true
      (Sol_cli_workspace.find_root ~dir:tmpdir = None))
;;

let local_infra sol_yml =
  with_tmpdir (fun tmpdir ->
    write_file (Filename.concat tmpdir "sol.yml") sol_yml;
    match Sol_cli_config.local_infra ~root:tmpdir with
    | Ok req -> req
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e))
;;

let test_declared_resources_decide_infra () =
  let req =
    local_infra "resources:\n  app_db:\n    type: postgres\n  events:\n    type: kafka\n"
  in
  check_bool "postgres" true req.postgres;
  check_bool "kafka" true req.kafka
;;

let test_typescript_workspace_gets_its_postgres () =
  let req =
    local_infra
      "resources:\n\
      \  app_db:\n\
      \    type: postgres\n\
       services:\n\
      \  order_svc:\n\
      \    type: http\n\
      \    path: app/orders/order_svc\n\
      \    language: typescript\n\
      \    uses: [app_db]\n"
  in
  check_bool "postgres" true req.postgres;
  check_bool "no kafka declared" false req.kafka
;;

let test_observability_always_on () =
  let req = local_infra "project: bare\n" in
  check_bool "no postgres" false req.postgres;
  check_bool "no kafka" false req.kafka;
  check_bool "loki" true req.loki;
  check_bool "prometheus" true req.prometheus;
  check_bool "tempo" true req.tempo
;;

let test_omitted_resource_starts_nothing () =
  let req = local_infra "resources:\n  app_db:\n    type: postgres\n    omit: true\n" in
  check_bool "omitted postgres is not started" false req.postgres
;;

let test_enter_from_a_subdirectory () =
  with_tmpdir (fun tmpdir ->
    let root = Unix.realpath tmpdir in
    write_file (Filename.concat root "sol.yml") "project: p\n";
    let deep = Filename.concat root "app/payments/charge_svc" in
    mkdir_p deep;
    let before = Sys.getcwd () in
    Fun.protect
      ~finally:(fun () -> Sys.chdir before)
      (fun () ->
         Sys.chdir deep;
         let entered = Sol_cli_workspace.enter_cwd () |> Result.get_ok in
         Windtrap.equal Windtrap.string ~msg:"returns the root" root entered.root;
         Windtrap.equal
           Windtrap.string
           ~msg:"names the workspace"
           (Filename.basename root)
           entered.name;
         Windtrap.equal
           Windtrap.string
           ~msg:"cwd is the root"
           root
           (Unix.realpath (Sys.getcwd ()))))
;;

let test_symlinked_checkout_is_not_nested () =
  with_tmpdir (fun tmpdir ->
    let outer = Filename.concat tmpdir "ws" in
    let other = Filename.concat tmpdir "elsewhere" in
    mkdir_p outer;
    mkdir_p (Filename.concat other "examples/pluto");
    write_file (Filename.concat outer "sol.yml") "project: p\n";
    write_file (Filename.concat other "examples/pluto/sol.yml") "project: pluto\n";
    mkdir_p (Filename.concat outer "vendor");
    Unix.symlink other (Filename.concat outer "vendor/sol");
    match Sol_cli_workspace.validate ~root:outer with
    | Ok () -> ()
    | Error e -> Windtrap.fail (Sol_cli_workspace.workspace_error_to_string e))
;;

let test_migration_defaults_from_a_subdirectory () =
  with_tmpdir (fun tmpdir ->
    let root = Filename.concat tmpdir "shop" in
    let sub = Filename.concat root "app/payments" in
    mkdir_p sub;
    write_file (Filename.concat root "sol.yml") "";
    check_string
      "the workspace's migrations"
      (Filename.concat root "db/migrations")
      (Sol_cli_workspace.migrations_dir ~dir:sub);
    check_string
      "the table the deploy gate reads"
      (Sol_cli_migration.table_name ~workspace:(Sol_cli_workspace.workspace_name ~root))
      (Sol_cli_workspace.migrations_table ~dir:sub);
    check_string
      "named for the workspace, not the directory"
      "sol_shop_schema_migrations"
      (Sol_cli_workspace.migrations_table ~dir:sub))
;;

let%test "migration defaults: from a subdirectory" =
  test_migration_defaults_from_a_subdirectory ()
;;

let%test "find_root (DEC-024): workspace with no dune marker" =
  test_workspace_without_dune_marker ()
;;

let%test "find_root (DEC-024): nested in an OCaml repo" = test_nested_in_ocaml_repo ()
let%test "find_root (DEC-024): nested in a Node repo" = test_nested_in_node_repo ()

let%test "find_root (DEC-024): mixed OCaml + TS workspace" =
  test_mixed_ocaml_and_typescript_workspace ()
;;

let%test "find_root (DEC-024): descendant cwd" = test_descendant_cwd_resolves_root ()

let%test "find_root (DEC-024): sibling workspaces" =
  test_sibling_workspaces_resolve_independently ()
;;

let%test "find_root (DEC-024): sol.yml must be a file" = test_sol_yml_must_be_a_file ()
let%test "validation: nested workspace is rejected" = test_nested_workspace_is_rejected ()

let%test "validation: absence fails closed with guidance" =
  test_absence_fails_closed_with_guidance ()
;;

let%test "local infra: declared resources decide infra" =
  test_declared_resources_decide_infra ()
;;

let%test "local infra: a TypeScript workspace gets its Postgres" =
  test_typescript_workspace_gets_its_postgres ()
;;

let%test "local infra: observability always on" = test_observability_always_on ()

let%test "local infra: an omitted resource starts nothing" =
  test_omitted_resource_starts_nothing ()
;;

let%test "entry point: enter from a subdirectory" = test_enter_from_a_subdirectory ()

let%test "entry point: a symlinked checkout is not nested" =
  test_symlinked_checkout_is_not_nested ()
;;
