(* BUG-056: `sol up` plans from the same declared facts `sol deploy` does.

   A local plan used to be built with no declared configuration at all, so the
   same workspace rendered with fewer facts locally than against a target: no
   declared language (INFRA-073's readiness probe was the visible symptom), no
   `sol.yml` scale override, and no resource uses, so a Kafka-consuming worker
   got no consumer group. These tests plan one fixture workspace both ways and
   compare what a reader of the plan sees. *)

let check_bool = Alcotest.(check bool)
let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_strings = Alcotest.(check (list string))

let contains ~needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

let mkdirs path =
  let rec go path =
    if path <> "" && path <> "." && path <> "/" && not (Sys.file_exists path)
    then (
      go (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  go path
;;

let write_file path body =
  mkdirs (Filename.dirname path);
  let oc = open_out path in
  output_string oc body;
  close_out oc
;;

(* A fixture workspace, entered for the duration of [f] because the config and
   workspace readers resolve against the current directory. *)
let with_workspace files f =
  let dir = Filename.temp_file "sol_test_up_plan" "" in
  Sys.remove dir;
  mkdirs dir;
  List.iter (fun (rel, body) -> write_file (Filename.concat dir rel) body) files;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir cwd;
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
       Sys.chdir dir;
       f ())
;;

(* The workspace both plans are built from: an OCaml `-svc` with a scale floor,
   and an OCaml worker that uses the declared kafka resource. *)
let sol_yml =
  {|project: ws

resources:
  app_db:
    type: postgres
  events:
    type: kafka

services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    uses: [app_db]
    language: ocaml
    scale: { min: 3 }

  notify_worker:
    type: worker
    path: app/comms/notify_worker
    uses: [events]
    language: ocaml
    scale: { max: 4 }
|}
;;

let environments_yml =
  {|prod:
  targets:
    aws/us-east-1:
      cluster_name: ws-prod
|}
;;

let workspace =
  [ "sol.yml", sol_yml
  ; "sol/environments.yml", environments_yml
  ; "app/payments/charge_svc/Dockerfile", "FROM scratch\n"
  ; "app/payments/charge_svc/sol.toml", "[infra.scale]\nreplicas = 2\n"
  ; "app/comms/notify_worker/Dockerfile", "FROM scratch\n"
  ; "app/comms/notify_worker/sol.toml", "[infra.scale]\nreplicas = 2\n"
  ]
;;

let fail_on_error what = function
  | Ok value -> value
  | Error message -> Alcotest.fail (Printf.sprintf "%s: %s" what message)
;;

(* The two plans, each the way its own command builds them: local resolves
   `sol.yml` alone (there is no local target), a target resolves sol.yml ->
   environment -> target. *)
let plans () =
  let facts =
    Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) |> fail_on_error "workspace model"
  in
  let services = Sol_cli_workspace_model.services facts in
  let declared =
    Sol_cli_config.load_declared ~root:(Sys.getcwd ())
    |> Result.map_error Sol_cli_config.error_to_string
    |> fail_on_error "load_declared"
  in
  let local =
    Sol_cli_up_execution.local_plan
      ~requested_scope:"workspace"
      ~workspace:"ws"
      ~sha:"sha-under-test"
      ~facts
      ~declared
      services
    |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
    |> fail_on_error "local_plan"
  in
  let target_config =
    Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1"
    |> Result.map_error Sol_cli_config.error_to_string
    |> fail_on_error "load_for_target"
  in
  (* The same execution environment for both, so the only difference between the
     two plans is the configuration each command resolves. *)
  let env =
    Sol_cli_env_target.to_env_config
      ~name:"ws"
      (Sol_cli_env_target.local_defaults ~image_tag:"sha-under-test")
  in
  let target =
    Sol_cli_deployment_plan.of_services_result
      ~workspace:"ws"
      ~env
      ~facts
      ~declared:(Sol_cli_config.declared_of_config target_config)
      services
    |> fun result ->
    match result with
    | Ok plan -> plan
    | Error e ->
      Alcotest.fail
        (Printf.sprintf
           "of_services_result: %s"
           (Sol_cli_deployment_plan.plan_error_to_string e))
  in
  local, target
;;

let spec_named plan name =
  match
    List.find_opt
      (fun (s : Sol_cli_deployment_plan.service_spec) -> String.equal s.source_name name)
      plan.Sol_cli_deployment_plan.services
  with
  | Some spec -> spec
  | None -> Alcotest.fail (Printf.sprintf "no spec for %s" name)
;;

(* The acceptance: the two plans agree on the three facts a declared
   configuration supplies -- language, replicas and consumer groups. *)
let test_up_and_target_plans_agree () =
  with_workspace workspace (fun () ->
    let local, target = plans () in
    List.iter
      (fun name ->
         let from_local = spec_named local name in
         let from_target = spec_named target name in
         check_string
           (name ^ " language")
           (Option.fold
              ~none:"<none>"
              ~some:Sol_cli_compat.to_string
              from_target.Sol_cli_deployment_plan.language)
           (Option.fold
              ~none:"<none>"
              ~some:Sol_cli_compat.to_string
              from_local.Sol_cli_deployment_plan.language);
         check_int
           (name ^ " replicas")
           from_target.Sol_cli_deployment_plan.replicas
           from_local.Sol_cli_deployment_plan.replicas)
      [ "charge_svc"; "notify_worker" ];
    check_strings
      "consumer groups"
      (List.map
         Sol_cli_plan_ids.Consumer_group.to_string
         target.Sol_cli_deployment_plan.consumer_groups)
      (List.map
         Sol_cli_plan_ids.Consumer_group.to_string
         local.Sol_cli_deployment_plan.consumer_groups))
;;

(* The declared facts are really there, which is what makes the parity above
   non-vacuous: `scale: { min: 3 }` has to beat sol.toml's `replicas = 2`, and a
   worker that uses the kafka resource has to get a consumer group. *)
let test_local_plan_carries_the_declared_facts () =
  with_workspace workspace (fun () ->
    let local, _ = plans () in
    let charge_svc = spec_named local "charge_svc" in
    let notify_worker = spec_named local "notify_worker" in
    check_string
      "charge_svc declares OCaml"
      "ocaml"
      (Option.fold
         ~none:"<none>"
         ~some:Sol_cli_compat.to_string
         charge_svc.Sol_cli_deployment_plan.language);
    check_int "charge_svc takes sol.yml's scale floor over sol.toml" 3 charge_svc.replicas;
    check_int
      "notify_worker takes sol.yml's scale ceiling over sol.toml"
      4
      notify_worker.replicas;
    check_strings
      "the kafka consumer group is derived locally too"
      [ "ws.comms.notify_worker" ]
      (List.map
         Sol_cli_plan_ids.Consumer_group.to_string
         local.Sol_cli_deployment_plan.consumer_groups))
;;

(* Acceptance, second half: a plan `sol up` builds renders the readiness probe
   its declared language implies. INFRA-073 puts an OCaml `-svc` on /readyz, so
   the rendered manifest must say so -- the local TypeScript golden path failed
   on exactly this. *)
let test_local_plan_renders_readyz () =
  with_workspace workspace (fun () ->
    let local, _ = plans () in
    let charge_svc = spec_named local "charge_svc" in
    let rendered =
      match
        Sol_cli_deployment_render.render_spec
          ~workspace:"ws"
          ~release_id:
            (Sol_cli_release_id.of_content
               { workspace = "ws"; environment = None; workloads = [] })
          charge_svc
      with
      | Ok (_, workload) -> workload
      | Error e -> Alcotest.fail ("render_spec: " ^ e)
    in
    check_bool
      "readinessProbe points at /readyz"
      true
      (contains
         ~needle:"readinessProbe:\n          httpGet:\n            path: /readyz"
         rendered);
    check_bool
      "livenessProbe stays on /healthz"
      true
      (contains
         ~needle:"livenessProbe:\n          httpGet:\n            path: /healthz"
         rendered))
;;

(* A malformed sol.yml must still fail closed for `sol up`: the declared facts
   are now an input, so the error has to reach the caller rather than be read as
   "nothing declared". *)
let test_undeclared_workloads_still_plan () =
  with_workspace
    [ "sol.yml", "resources:\n  events:\n    type: kafka\n"
    ; "app/comms/notify_worker/Dockerfile", "FROM scratch\n"
    ; "app/comms/notify_worker/sol.toml", "[infra.scale]\nreplicas = 1\n"
    ]
  @@ fun () ->
  let facts =
    Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) |> fail_on_error "workspace model"
  in
  let declared =
    Sol_cli_config.load_declared ~root:(Sys.getcwd ())
    |> Result.map_error Sol_cli_config.error_to_string
    |> fail_on_error "load_declared"
  in
  let plan =
    Sol_cli_up_execution.local_plan
      ~requested_scope:"workspace"
      ~workspace:"ws"
      ~sha:"sha"
      ~facts
      ~declared
      (Sol_cli_workspace_model.services facts)
    |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
    |> fail_on_error "local_plan"
  in
  let worker = spec_named plan "notify_worker" in
  check_string
    "an undeclared language stays unknown"
    "<none>"
    (Option.fold
       ~none:"<none>"
       ~some:Sol_cli_compat.to_string
       worker.Sol_cli_deployment_plan.language);
  check_strings
    "an undeclared resource use yields no consumer group"
    []
    (List.map
       Sol_cli_plan_ids.Consumer_group.to_string
       plan.Sol_cli_deployment_plan.consumer_groups)
;;

let () =
  Alcotest.run
    "sol_cli_up_plan"
    [ ( "sol up and sol deploy plan the same workspace (BUG-056)"
      , [ Alcotest.test_case
            "the two plans agree on language, replicas and consumer groups"
            `Quick
            test_up_and_target_plans_agree
        ; Alcotest.test_case
            "the local plan carries the declared facts"
            `Quick
            test_local_plan_carries_the_declared_facts
        ; Alcotest.test_case
            "a local plan renders /readyz for a declared OCaml service"
            `Quick
            test_local_plan_renders_readyz
        ; Alcotest.test_case
            "an undeclared workspace still plans, as unknown"
            `Quick
            test_undeclared_workloads_still_plan
        ] )
    ]
;;
