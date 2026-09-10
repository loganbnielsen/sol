let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let mkdir_p path =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))

let with_tmp f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("sol-factory-" ^ string_of_int (Random.bits ()))
  in
  mkdir_p root;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root))))
    (fun () ->
      let cwd = Sys.getcwd () in
      Fun.protect
        ~finally:(fun () -> Sys.chdir cwd)
        (fun () ->
          Sys.chdir root;
          f root))

let env : Sol_cli_deployment_plan.env_config =
  {
    name = "myapp";
    mode = Sol_cli_deployment_plan.Local;
    registry = "localhost:5000";
    image_tag = "abc123";
    env = None;
    region = None;
    base_domain = None;
    secret_backend = Sol_cli_manifest.Kubernetes_placeholder;
  }

let test_run_without_cmdliner () =
  with_tmp (fun root ->
      mkdir_p "app/payments/charge_svc";
      write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
      write "app/payments/charge_svc/sol.toml"
        "[infra.env]\nsecrets = [\"DATABASE_URL\"]\n";
      let emit_dir = Filename.concat root "out" in
      match
        Sol_cli_factory.run ~workspace:"myapp" ~env ~filter_path:None
          ~mode:(Sol_cli_executor.Emit_to emit_dir) ()
      with
      | Error msg -> Alcotest.fail ("factory run failed: " ^ msg)
      | Ok execution ->
          Alcotest.(check int)
            "one result" 1
            (List.length execution.Sol_cli_factory.results);
          let facts =
            Sol_cli_factory.affected_services ~plan:execution.plan
              ~results:execution.results
          in
          Alcotest.(check int) "one release fact" 1 (List.length facts);
          let emitted =
            Filename.concat emit_dir "myapp-payments-charge-svc.yaml"
          in
          Alcotest.(check bool)
            "manifest emitted" true (Sys.file_exists emitted))

let test_plan_missing_app () =
  with_tmp (fun _ ->
      match Sol_cli_factory.plan ~workspace:"myapp" ~env ~filter_path:None with
      | Ok _ -> Alcotest.fail "expected missing app error"
      | Error msg ->
          Alcotest.(check bool) "actionable error" true (String.length msg > 0))

let () =
  Alcotest.run "factory"
    [
      ( "boundary",
        [
          Alcotest.test_case "run without cmdliner" `Quick
            test_run_without_cmdliner;
          Alcotest.test_case "plan missing app" `Quick test_plan_missing_app;
        ] );
    ]
