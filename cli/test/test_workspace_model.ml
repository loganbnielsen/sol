let fixture rel = if Sys.file_exists rel then rel else Filename.concat "../../../../" rel

let tmpdir () =
  let dir = Filename.temp_file "sol-model-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let with_tmp f =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree dir)) (fun () -> f dir)
;;

let write dir rel content =
  let path = Filename.concat dir rel in
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

let load rel =
  match Sol_cli_workspace_model.load ~root:(fixture rel) with
  | Ok facts -> facts
  | Error e -> Alcotest.fail (rel ^ " failed to load: " ^ e)
;;

let service_names facts =
  Sol_cli_workspace_model.services facts
  |> List.map (fun (s : Sol_cli_manifest.service) -> s.name)
  |> List.sort String.compare
;;

let languages facts =
  facts.Sol_cli_workspace_model.workloads
  |> List.filter_map (fun (w : Sol_cli_workspace_model.workload) ->
    Option.map
      (fun language ->
         w.Sol_cli_workspace_model.service.Sol_cli_manifest.name
         ^ "="
         ^ Sol_cli_compat.to_string language)
      w.Sol_cli_workspace_model.language)
  |> List.sort String.compare
;;

let subject_strings facts =
  facts.Sol_cli_workspace_model.schema_subjects
  |> List.map Sol_cli_plan_ids.Schema_subject.to_string
;;

let test_pluto_services_carry_their_primitive_and_language () =
  let facts = load "examples/pluto" in
  Alcotest.(check (list string))
    "services"
    [ "charge_svc"; "checkout_svc"; "fulfillment_worker"; "notify_worker"; "order_svc" ]
    (service_names facts);
  Alcotest.(check string) "root" (fixture "examples/pluto") facts.root;
  Alcotest.(check (list string))
    "declared languages"
    [ "charge_svc=ocaml"
    ; "checkout_svc=ocaml"
    ; "fulfillment_worker=typescript"
    ; "notify_worker=ocaml"
    ; "order_svc=typescript"
    ]
    (languages facts);
  let primitives =
    Sol_cli_workspace_model.services facts
    |> List.map (fun (s : Sol_cli_manifest.service) ->
      s.name ^ "=" ^ Sol_cli_manifest.primitive_label s.primitive)
    |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "primitives"
    [ "charge_svc=svc"
    ; "checkout_svc=svc"
    ; "fulfillment_worker=worker"
    ; "notify_worker=worker"
    ; "order_svc=svc"
    ]
    primitives;
  Alcotest.(check int)
    "workload count"
    (List.length (Sol_cli_workspace_model.services facts))
    (List.length facts.Sol_cli_workspace_model.workloads)
;;

let test_pluto_events_migrations_and_targets () =
  let facts = load "examples/pluto" in
  Alcotest.(check (list string))
    "schema subjects"
    [ "comms.Notification_sent"; "payments.Charged" ]
    (subject_strings facts);
  Alcotest.(check (list string))
    "topics (pluto's events declare none)"
    []
    (List.map Sol_cli_plan_ids.Topic_name.to_string facts.Sol_cli_workspace_model.topics);
  Alcotest.(check (list string))
    "declared targets"
    [ "customer_cloud/aws/us-east-1"
    ; "dev/aws/us-east-1"
    ; "pilot/aws/us-east-1"
    ; "prod/aws/us-east-1"
    ]
    facts.Sol_cli_workspace_model.targets;
  (match facts.Sol_cli_workspace_model.migrations with
   | [ notifications; sol_jobs; sol_outbox ] ->
     Alcotest.(check string)
       "file"
       "0001_notifications.sql"
       (Sol_cli_plan_ids.Migration_file.to_string notifications.file);
     Alcotest.(check (option int)) "version" (Some 1) notifications.version;
     Alcotest.(check (option string)) "name" (Some "notifications") notifications.name;
     (match notifications.disposition with
      | Ok _ -> Alcotest.fail "expected pluto's migration to declare no disposition"
      | Error _ -> ());
     Alcotest.(check string)
       "sol-jobs migration file"
       "0002_sol_jobs.sql"
       (Sol_cli_plan_ids.Migration_file.to_string sol_jobs.file);
     Alcotest.(check (option int)) "sol-jobs version" (Some 2) sol_jobs.version;
     Alcotest.(check (option string)) "sol-jobs name" (Some "sol_jobs") sol_jobs.name;
     Alcotest.(check string)
       "sol-outbox migration file"
       "0003_sol_outbox.sql"
       (Sol_cli_plan_ids.Migration_file.to_string sol_outbox.file);
     Alcotest.(check (option int)) "sol-outbox version" (Some 3) sol_outbox.version;
     Alcotest.(check (option string))
       "sol-outbox name"
       (Some "sol_outbox")
       sol_outbox.name
   | other ->
     Alcotest.fail
       (Printf.sprintf "expected three migrations, got %d" (List.length other)));
  Alcotest.(check int)
    "unapplied migrations"
    3
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

let test_venus_reads_both_domains () =
  let facts = load "internal/fixtures/venus" in
  Alcotest.(check (list string))
    "services"
    [ "fulfillment_worker"; "notify_worker" ]
    (service_names facts);
  Alcotest.(check (list string))
    "schema subjects"
    [ "billing.Payment_confirmed"; "payments.Charged" ]
    (subject_strings facts);
  Alcotest.(check (list string))
    "topics (no event sol.toml here)"
    []
    (List.map Sol_cli_plan_ids.Topic_name.to_string facts.Sol_cli_workspace_model.topics);
  Alcotest.(check (list string))
    "declared targets (none)"
    []
    facts.Sol_cli_workspace_model.targets;
  Alcotest.(check int)
    "unapplied migrations"
    3
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

let test_local_demo_is_an_empty_workspace () =
  let facts = load "internal/fixtures/local-demo" in
  Alcotest.(check (option string)) "no app dir" None facts.Sol_cli_workspace_model.app_dir;
  Alcotest.(check (list string)) "no services" [] (service_names facts);
  Alcotest.(check (list string)) "no targets" [] facts.Sol_cli_workspace_model.targets;
  Alcotest.(check int)
    "no migrations"
    0
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

let expect_error_mentioning ~needle = function
  | Ok _ -> Alcotest.fail "expected the load to fail"
  | Error message ->
    Alcotest.(check bool)
      (Printf.sprintf "%S names %S" message needle)
      true
      (Sol_cli_string.contains ~needle message)
;;

let test_malformed_sol_yml_names_the_file () =
  with_tmp (fun dir ->
    write dir "sol.yml" "services:\n  api:\n    language: ocaml\n  :\n";
    expect_error_mentioning ~needle:"sol.yml" (Sol_cli_workspace_model.load ~root:dir))
;;

let test_malformed_environments_file_names_it () =
  with_tmp (fun dir ->
    write dir "sol.yml" "";
    write dir "sol/environments.yml" "prod:\n  targets:\n    - not-a-mapping\n";
    expect_error_mentioning
      ~needle:"sol/environments.yml"
      (Sol_cli_workspace_model.load ~root:dir))
;;

let test_malformed_event_toml_names_it () =
  with_tmp (fun dir ->
    write dir "sol.yml" "";
    write dir "events/payments/sol.toml" "[service]\ntopic = [\"payments.charged\"]\n";
    expect_error_mentioning
      ~needle:"events/payments/sol.toml"
      (Sol_cli_workspace_model.load ~root:dir))
;;

let test_malformed_workload_toml_is_carried_not_fatal () =
  with_tmp (fun dir ->
    write dir "sol.yml" "";
    write dir "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write dir "app/payments/charge_svc/sol.toml" "[infra.deploy]\nbad key = 1\n";
    match Sol_cli_workspace_model.load ~root:dir with
    | Error e -> Alcotest.fail ("a workload sol.toml must not fail the load: " ^ e)
    | Ok facts ->
      (match facts.Sol_cli_workspace_model.workloads with
       | [ workload ] ->
         (match workload.config with
          | Ok _ ->
            Alcotest.fail "expected the malformed sol.toml to be carried as an error"
          | Error err ->
            Alcotest.(check bool)
              "the carried error names the file"
              true
              (Sol_cli_string.contains
                 ~needle:"sol.toml"
                 (Sol_cli_toml.parse_error_to_string err)))
       | other ->
         Alcotest.fail
           (Printf.sprintf "expected one workload, got %d" (List.length other))))
;;

let test_empty_app_dir_is_not_a_missing_app_dir () =
  with_tmp (fun dir ->
    write dir "sol.yml" "";
    Unix.mkdir (Filename.concat dir "app") 0o755;
    match Sol_cli_workspace_model.load ~root:dir with
    | Error e -> Alcotest.fail ("expected an empty workspace to load: " ^ e)
    | Ok facts ->
      Alcotest.(check bool)
        "app_dir present"
        true
        (Option.is_some facts.Sol_cli_workspace_model.app_dir);
      Alcotest.(check (list string)) "no services" [] (service_names facts))
;;

let () =
  Alcotest.run
    "sol_cli_workspace_model"
    [ ( "fixtures"
      , [ Alcotest.test_case
            "pluto: services carry primitive and language"
            `Quick
            test_pluto_services_carry_their_primitive_and_language
        ; Alcotest.test_case
            "pluto: events, migrations and targets"
            `Quick
            test_pluto_events_migrations_and_targets
        ; Alcotest.test_case "venus: both domains" `Quick test_venus_reads_both_domains
        ; Alcotest.test_case
            "local-demo: an empty workspace"
            `Quick
            test_local_demo_is_an_empty_workspace
        ; Alcotest.test_case
            "an empty app/ is not a missing app/"
            `Quick
            test_empty_app_dir_is_not_a_missing_app_dir
        ] )
    ; ( "malformed files name the file"
      , [ Alcotest.test_case "sol.yml" `Quick test_malformed_sol_yml_names_the_file
        ; Alcotest.test_case
            "sol/environments.yml"
            `Quick
            test_malformed_environments_file_names_it
        ; Alcotest.test_case "event sol.toml" `Quick test_malformed_event_toml_names_it
        ; Alcotest.test_case
            "a workload sol.toml is carried, not fatal"
            `Quick
            test_malformed_workload_toml_is_carried_not_fatal
        ] )
    ]
;;
