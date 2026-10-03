let fixture rel = Filename.concat (Source_root.find ()) rel

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
  | Error e -> Windtrap.fail (rel ^ " failed to load: " ^ e)
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
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"services"
    [ "charge_svc"; "checkout_svc"; "fulfillment_worker"; "notify_worker"; "order_svc" ]
    (service_names facts);
  Windtrap.equal Windtrap.string ~msg:"root" (fixture "examples/pluto") facts.root;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"declared languages"
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
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"primitives"
    [ "charge_svc=svc"
    ; "checkout_svc=svc"
    ; "fulfillment_worker=worker"
    ; "notify_worker=worker"
    ; "order_svc=svc"
    ]
    primitives;
  Windtrap.equal
    Windtrap.int
    ~msg:"workload count"
    (List.length (Sol_cli_workspace_model.services facts))
    (List.length facts.Sol_cli_workspace_model.workloads)
;;

let test_pluto_events_migrations_and_targets () =
  let facts = load "examples/pluto" in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"schema subjects"
    [ "comms.Notification_sent"; "payments.Charged" ]
    (subject_strings facts);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"topics (pluto's events declare none)"
    []
    (List.map Sol_cli_plan_ids.Topic_name.to_string facts.Sol_cli_workspace_model.topics);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"declared targets"
    [ "customer_cloud/aws/us-east-1"
    ; "customer_cloud/byo/onprem"
    ; "dev/aws/us-east-1"
    ; "pilot/aws/us-east-1"
    ; "prod/aws/us-east-1"
    ]
    facts.Sol_cli_workspace_model.targets;
  (match facts.Sol_cli_workspace_model.migrations with
   | [ notifications; sol_jobs; sol_outbox; charge_id_unique ] ->
     Windtrap.equal
       Windtrap.string
       ~msg:"file"
       "0001_notifications.sql"
       (Sol_cli_plan_ids.Migration_file.to_string notifications.file);
     Windtrap.equal
       (Windtrap.option Windtrap.int)
       ~msg:"version"
       (Some 1)
       notifications.version;
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"name"
       (Some "notifications")
       notifications.name;
     (match notifications.disposition with
      | Ok _ -> Windtrap.fail "expected pluto's migration to declare no disposition"
      | Error _ -> ());
     Windtrap.equal
       Windtrap.string
       ~msg:"sol-jobs migration file"
       "0002_sol_jobs.sql"
       (Sol_cli_plan_ids.Migration_file.to_string sol_jobs.file);
     Windtrap.equal
       (Windtrap.option Windtrap.int)
       ~msg:"sol-jobs version"
       (Some 2)
       sol_jobs.version;
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"sol-jobs name"
       (Some "sol_jobs")
       sol_jobs.name;
     Windtrap.equal
       Windtrap.string
       ~msg:"sol-outbox migration file"
       "0003_sol_outbox.sql"
       (Sol_cli_plan_ids.Migration_file.to_string sol_outbox.file);
     Windtrap.equal
       (Windtrap.option Windtrap.int)
       ~msg:"sol-outbox version"
       (Some 3)
       sol_outbox.version;
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"sol-outbox name"
       (Some "sol_outbox")
       sol_outbox.name;
     Windtrap.equal
       Windtrap.string
       ~msg:"charge-id-unique migration file"
       "0004_notifications_charge_id_unique.sql"
       (Sol_cli_plan_ids.Migration_file.to_string charge_id_unique.file);
     Windtrap.equal
       (Windtrap.option Windtrap.int)
       ~msg:"charge-id-unique version"
       (Some 4)
       charge_id_unique.version;
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"charge-id-unique name"
       (Some "notifications_charge_id_unique")
       charge_id_unique.name
   | other ->
     Windtrap.fail (Printf.sprintf "expected four migrations, got %d" (List.length other)));
  Windtrap.equal
    Windtrap.int
    ~msg:"unapplied migrations"
    4
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

let test_venus_reads_both_domains () =
  let facts = load "internal/fixtures/venus" in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"services"
    [ "fulfillment_worker"; "notify_worker" ]
    (service_names facts);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"schema subjects"
    [ "billing.Payment_confirmed"; "payments.Charged" ]
    (subject_strings facts);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"topics (no event sol.toml here)"
    []
    (List.map Sol_cli_plan_ids.Topic_name.to_string facts.Sol_cli_workspace_model.topics);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"declared targets (none)"
    []
    facts.Sol_cli_workspace_model.targets;
  Windtrap.equal
    Windtrap.int
    ~msg:"unapplied migrations"
    3
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

let test_local_demo_is_an_empty_workspace () =
  let facts = load "internal/fixtures/local-demo" in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"no app dir"
    None
    facts.Sol_cli_workspace_model.app_dir;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"no services"
    []
    (service_names facts);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"no targets"
    []
    facts.Sol_cli_workspace_model.targets;
  Windtrap.equal
    Windtrap.int
    ~msg:"no migrations"
    0
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

let expect_error_mentioning ~needle = function
  | Ok _ -> Windtrap.fail "expected the load to fail"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "%S names %S" message needle)
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
    | Error e -> Windtrap.fail ("a workload sol.toml must not fail the load: " ^ e)
    | Ok facts ->
      (match facts.Sol_cli_workspace_model.workloads with
       | [ workload ] ->
         (match workload.config with
          | Ok _ ->
            Windtrap.fail "expected the malformed sol.toml to be carried as an error"
          | Error err ->
            Windtrap.equal
              Windtrap.bool
              ~msg:"the carried error names the file"
              true
              (Sol_cli_string.contains
                 ~needle:"sol.toml"
                 (Sol_cli_toml.parse_error_to_string err)))
       | other ->
         Windtrap.fail
           (Printf.sprintf "expected one workload, got %d" (List.length other))))
;;

let test_empty_app_dir_is_not_a_missing_app_dir () =
  with_tmp (fun dir ->
    write dir "sol.yml" "";
    Unix.mkdir (Filename.concat dir "app") 0o755;
    match Sol_cli_workspace_model.load ~root:dir with
    | Error e -> Windtrap.fail ("expected an empty workspace to load: " ^ e)
    | Ok facts ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"app_dir present"
        true
        (Option.is_some facts.Sol_cli_workspace_model.app_dir);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no services"
        []
        (service_names facts))
;;

let%test "fixtures: pluto: services carry primitive and language" =
  test_pluto_services_carry_their_primitive_and_language ()
;;

let%test "fixtures: pluto: events, migrations and targets" =
  test_pluto_events_migrations_and_targets ()
;;

let%test "fixtures: venus: both domains" = test_venus_reads_both_domains ()

let%test "fixtures: local-demo: an empty workspace" =
  test_local_demo_is_an_empty_workspace ()
;;

let%test "fixtures: an empty app/ is not a missing app/" =
  test_empty_app_dir_is_not_a_missing_app_dir ()
;;

let%test "malformed files name the file: sol.yml" =
  test_malformed_sol_yml_names_the_file ()
;;

let%test "malformed files name the file: sol/environments.yml" =
  test_malformed_environments_file_names_it ()
;;

let%test "malformed files name the file: event sol.toml" =
  test_malformed_event_toml_names_it ()
;;

let%test "malformed files name the file: a workload sol.toml is carried, not fatal" =
  test_malformed_workload_toml_is_carried_not_fatal ()
;;
