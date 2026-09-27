(* REFAC-130: the workspace model loaded over the real fixture workspaces.

   [examples/pluto] is the canonical reference application (OCaml and
   TypeScript workloads, events, migrations, declared targets); [venus] is the
   OCaml fixture whose layout the deployment tests use; [local-demo] is a
   fixture with no [sol.yml] and no [app/] at all, which the loader must read as
   "no workloads", not as an error.

   These tests are also where "the errors name the file" is pinned: a malformed
   [sol.yml], [sol/environments.yml] or event [sol.toml] fails the load with the
   offending path in the message. *)

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

(* ── examples/pluto: every fact the model carries ───────────────────────── *)

let test_pluto_services_carry_their_primitive_and_language () =
  let facts = load "examples/pluto" in
  Alcotest.(check (list string))
    "services"
    [ "charge_svc"; "checkout_svc"; "fulfillment_worker"; "notify_worker"; "order_svc" ]
    (service_names facts);
  (* The model names the root it read, so a caller holding only the value can
     say which workspace it describes. *)
  Alcotest.(check string) "root" (fixture "examples/pluto") facts.root;
  (* The declared language comes from each workload's sol.yml entry; nothing is
     inferred from build metadata (DEC-022 §7). *)
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
  (* Every workload with a Dockerfile is a service; the workload list is the
     same set here, since pluto's five workloads all have one. *)
  Alcotest.(check int)
    "workload count"
    (List.length (Sol_cli_workspace_model.services facts))
    (List.length facts.Sol_cli_workspace_model.workloads)
;;

let test_pluto_events_migrations_and_targets () =
  let facts = load "examples/pluto" in
  Alcotest.(check (list string))
    "schema subjects"
    [ "payments.Charged" ]
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
  (* The migration is typed: its version and name come from the filename. *)
  (match facts.Sol_cli_workspace_model.migrations with
   | [ migration ] ->
     Alcotest.(check string)
       "file"
       "0001_notifications.sql"
       (Sol_cli_plan_ids.Migration_file.to_string migration.file);
     Alcotest.(check (option int)) "version" (Some 1) migration.version;
     Alcotest.(check (option string)) "name" (Some "notifications") migration.name;
     (* This file declares no disposition header, which the rollback gate
        reports. It is carried as a finding, not a load failure. *)
     (match migration.disposition with
      | Ok _ -> Alcotest.fail "expected pluto's migration to declare no disposition"
      | Error _ -> ())
   | other ->
     Alcotest.fail (Printf.sprintf "expected one migration, got %d" (List.length other)));
  Alcotest.(check int)
    "unapplied migrations"
    1
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

(* ── internal/fixtures/venus ────────────────────────────────────────────── *)

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
    1
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

(* A fixture with no sol.yml and no app/: an empty workspace, not an error.
   [app_dir] is what keeps "there is no app/" distinguishable from "app/ is
   empty", which sol check reports differently. *)
let test_local_demo_is_an_empty_workspace () =
  let facts = load "internal/fixtures/local-demo" in
  Alcotest.(check (option string)) "no app dir" None facts.Sol_cli_workspace_model.app_dir;
  Alcotest.(check (list string)) "no services" [] (service_names facts);
  Alcotest.(check (list string)) "no targets" [] facts.Sol_cli_workspace_model.targets;
  (* Its migrations live in [migrations/], not [db/migrations/], so the workspace
     has none -- the loader reads the workspace's own layout, not a guessed one. *)
  Alcotest.(check int)
    "no migrations"
    0
    (Sol_cli_workspace_model.count_unapplied_migrations facts)
;;

(* ── malformed content: the error names the file ────────────────────────── *)

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

(* A malformed workload [sol.toml] is a *finding*, not a load failure: [sol
   check] exists to report it, so the model carries it. *)
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

(* ── app dir presence, and a workspace with no app/ ─────────────────────── *)

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
