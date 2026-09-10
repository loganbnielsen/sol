let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

let contains_substring ~needle s =
  let ln = String.length needle in
  let ls = String.length s in
  if ln = 0
  then true
  else if ln > ls
  then false
  else (
    let rec go i =
      if i > ls - ln
      then false
      else if String.sub s i ln = needle
      then true
      else go (i + 1)
    in
    go 0)
;;

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let cpu s =
  match Sol_cli_toml.cpu_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message
;;

let memory s =
  match Sol_cli_toml.memory_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message
;;

let service
      ?(name = "charge-svc")
      ?(primitive = Sol_cli_deployment_plan.Svc)
      ?progressive_delivery
      ()
  =
  { Sol_cli_deployment_plan.domain = "payments"
  ; source_name = name
  ; k8s_name = k8s_name name
  ; namespace =
      Sol_cli_deployment_plan.namespace_of_exn ~workspace:"pluto" ~domain:"payments"
  ; primitive
  ; source_dir = "payments/" ^ name
  ; image = "registry.sol.dev/acct_123/pluto/" ^ name ^ ":abc123"
  ; config = [ "LOG_LEVEL", "info" ]
  ; secrets = [ "DATABASE_URL", "postgres://secret" ]
  ; volumes = []
  ; schedule = None
  ; replicas = 2
  ; cpu = cpu "250m"
  ; memory = memory "256Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; extra_labels = []
  ; progressive_delivery
  }
;;

let hosted_plan ?progressive_delivery () =
  let env : Sol_cli_deployment_plan.env_config =
    { name = "production"
    ; mode = Sol_cli_deployment_plan.Sol_hosted
    ; registry = "registry.sol.dev/acct_123"
    ; image_tag = "abc123"
    ; env = Some "prod"
    ; region = Some "us-east-1"
    ; base_domain = Some "sol.example"
    ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
    }
  in
  { Sol_cli_deployment_plan.workspace = "pluto"
  ; environment = env
  ; services =
      [ service ?progressive_delivery ()
      ; service ~name:"notify-worker" ~primitive:Sol_cli_deployment_plan.Worker ()
      ]
  ; topics =
      (match Sol_cli_plan_ids.Topic_name.of_string "charged" with
       | Ok t -> [ t ]
       | Error _ -> [])
  ; migrations =
      (match Sol_cli_plan_ids.Migration_file.of_string "0001_notifications.sql" with
       | Ok m -> [ m ]
       | Error _ -> [])
  ; schema_subjects = []
  ; consumer_groups = []
  }
;;

let image_refs : Sol_cli_release_inspection.image_ref list =
  [ { Sol_cli_release_inspection.service_name = "charge-svc"
    ; image = "ghcr.io/acme/charge@sha256:111"
    }
  ; { Sol_cli_release_inspection.service_name = "notify-worker"
    ; image = "ghcr.io/acme/notify@sha256:222"
    }
  ]
;;

let release_for plan =
  let services =
    List.map2
      (fun service (image_ref : Sol_cli_release_inspection.image_ref) ->
         Sol_cli_release_inspection.affected_service
           ~image:image_ref.Sol_cli_release_inspection.image
           service)
      plan.Sol_cli_deployment_plan.services
      image_refs
  in
  Sol_cli_release_inspection.release_summary
    ~release_id:"rel_env-prod_abc123"
    ~environment_id:"env_prod"
    ~environment_name:"production"
    ~status:Sol_cli_release_inspection.Mock_submitted
    ~plan
    ~image_refs
    ~services
;;

let test_release_summary_json () =
  let plan = hosted_plan () in
  let release = release_for plan in
  let json = Sol_cli_release_inspection.release_summary_to_json release in
  let open Yojson.Safe.Util in
  check_string
    "release id"
    "rel_env-prod_abc123"
    (json |> member "release_id" |> to_string);
  check_string
    "mode"
    "sol_hosted"
    (json |> member "deployment_plan" |> member "mode" |> to_string);
  check_int
    "service count"
    2
    (json |> member "deployment_plan" |> member "service_count" |> to_int);
  check_string
    "rollout status default"
    "unknown"
    (json |> member "services" |> index 0 |> member "rollout_status" |> to_string);
  check_bool
    "secret values absent"
    false
    (contains_substring ~needle:"postgres://secret" (Yojson.Safe.to_string json))
;;

let test_rendered_manifest_diagnostics () =
  let progressive_delivery =
    Some
      (Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 10; Sol_cli_toml.Pause None ] })
  in
  let plan = hosted_plan ?progressive_delivery () in
  let manifests = Sol_cli_release_inspection.rendered_manifests_of_plan plan in
  check_int "manifest count" 14 (List.length manifests);
  let rollout =
    List.find
      (fun (m : Sol_cli_release_inspection.rendered_manifest) ->
         m.name = "charge-svc" && m.kind = "Rollout")
      manifests
  in
  check_string "rollout kind" "Rollout" rollout.kind;
  (* FEAT-026: rollout_doc (progressive-delivery path) gets ?env too, and
     rendered_manifests_of_plan threads it from plan.environment.env -- the
     only other render paths tested for this are deployment_doc/cronjob_doc
     (test_manifest_render.ml), not rollout_doc, and this is also the one
     place that previously dropped plan.environment.env entirely. *)
  check_bool
    "rollout carries env label"
    true
    (contains_substring ~needle:{|env: "prod"|} rollout.yaml);
  let ingress =
    List.find
      (fun (m : Sol_cli_release_inspection.rendered_manifest) ->
         m.name = "charge-svc" && m.kind = "Ingress")
      manifests
  in
  check_string "ingress kind" "Ingress" ingress.kind;
  let release = release_for plan in
  let event : Sol_cli_release_inspection.diagnostic_event =
    { source = "hosted-control-plane"
    ; reason = "Progressing"
    ; message = "rollout accepted by mock executor"
    ; severity = "info"
    }
  in
  let diagnostics =
    Sol_cli_release_inspection.diagnostics
      ~rendered_manifests:manifests
      ~reconciliation_events:[ event ]
      ~rollout_resources:[ "charge-svc" ]
      release
  in
  let json = Sol_cli_release_inspection.diagnostics_to_json diagnostics in
  let open Yojson.Safe.Util in
  check_string
    "rollout resource"
    "charge-svc"
    (json |> member "rollout_resources" |> index 0 |> to_string);
  check_string
    "event reason"
    "Progressing"
    (json |> member "reconciliation_events" |> index 0 |> member "reason" |> to_string)
;;

let () =
  Alcotest.run
    "release_inspection"
    [ ( "summary"
      , [ Alcotest.test_case "release summary json" `Quick test_release_summary_json ] )
    ; ( "diagnostics"
      , [ Alcotest.test_case
            "rendered manifests"
            `Quick
            test_rendered_manifest_diagnostics
        ] )
    ]
;;
