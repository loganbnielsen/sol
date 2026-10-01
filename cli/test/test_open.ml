let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

module O = Sol_cli_open

let contains url sub = Sol_cli_string.contains ~needle:sub url

let ok_url = function
  | Ok s -> s
  | Error msg -> Alcotest.fail ("expected Ok, got Error " ^ msg)
;;

let err_msg = function
  | Ok s -> Alcotest.fail ("expected Error, got Ok " ^ s)
  | Error msg -> msg
;;

let test_parse_scope_none () =
  check_bool "None -> Workspace" true (O.parse_scope None = Ok O.Workspace)
;;

let test_parse_scope_domain () =
  check_bool
    "domain only"
    true
    (O.parse_scope (Some "payments") = Ok (O.Domain "payments"))
;;

let test_parse_scope_domain_service () =
  check_bool
    "domain/service"
    true
    (O.parse_scope (Some "payments/charge-svc")
     = Ok (O.Service ("payments", "charge-svc")))
;;

let test_parse_scope_too_many_segments () =
  check_bool
    "extra slash -> Error"
    true
    (match O.parse_scope (Some "a/b/c") with
     | Error _ -> true
     | Ok _ -> false)
;;

let test_parse_scope_resource () =
  check_bool
    "resource/<type>/<name>"
    true
    (O.parse_scope (Some "resource/rds/acme-prod-postgres")
     = Ok (O.Resource ("rds", "acme-prod-postgres")))
;;

let base_url = "http://localhost:3000"
let workspace = "myapp"

let test_dashboard_workspace_scope () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard O.Workspace) in
  check_string
    "workspace dashboard"
    "http://localhost:3000/d/sol-workspace-overview?var-workspace=myapp"
    url
;;

let test_dashboard_domain_scope () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Domain "payments")) in
  check_bool "uses service-template uid" true (contains url "/d/sol-service-template");
  check_bool "presets var-workspace" true (contains url "var-workspace=myapp");
  check_bool "presets var-domain" true (contains url "var-domain=payments");
  check_bool "no var-service" false (contains url "var-service")
;;

let test_dashboard_service_scope () =
  let url =
    ok_url
      (O.url
         ~base_url
         ~workspace
         ~kind:O.Dashboard
         (O.Service ("payments", "charge-svc")))
  in
  check_bool "presets var-workspace" true (contains url "var-workspace=myapp");
  check_bool "presets var-domain" true (contains url "var-domain=payments");
  check_bool "presets var-service" true (contains url "var-service=charge-svc")
;;

let test_dashboard_workspace_scope_normalizes_case_and_underscore () =
  let url = ok_url (O.url ~base_url ~workspace:"My_App" ~kind:O.Dashboard O.Workspace) in
  check_bool
    "var-workspace uses the normalized (lowercase, hyphenated) name"
    true
    (contains url "var-workspace=my-app")
;;

let test_metrics_matches_dashboard () =
  let dashboard =
    ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Domain "payments"))
  in
  let metrics =
    ok_url (O.url ~base_url ~workspace ~kind:O.Metrics (O.Domain "payments"))
  in
  check_string "metrics == dashboard target" dashboard metrics
;;

let test_dashboard_service_scope_normalizes_underscore_name () =
  let url =
    ok_url
      (O.url
         ~base_url
         ~workspace
         ~kind:O.Dashboard
         (O.Service ("payments", "charge_svc")))
  in
  check_bool
    "var-service uses the normalized (hyphenated) name"
    true
    (contains url "var-service=charge-svc")
;;

let test_dashboard_domain_scope_normalizes_case_and_underscore () =
  let url =
    ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Domain "Payments_Team"))
  in
  check_bool
    "var-domain uses the normalized (lowercase, hyphenated) name"
    true
    (contains url "var-domain=payments-team")
;;

let test_dashboard_domain_scope_normalizes_internal_space () =
  let url =
    ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Domain "Payments Team"))
  in
  check_bool
    "var-domain replaces the internal space"
    true
    (contains url "var-domain=payments-team")
;;

let test_dashboard_service_scope_invalid_name () =
  let result =
    O.url ~base_url ~workspace ~kind:O.Dashboard (O.Service ("payments", ""))
  in
  check_bool "empty service name -> Error" true (String.length (err_msg result) > 0)
;;

let test_dashboard_resource_scope () =
  let url =
    ok_url
      (O.url
         ~base_url
         ~workspace
         ~kind:O.Dashboard
         (O.Resource ("rds", "acme-prod-postgres")))
  in
  check_string
    "managed resource dashboard"
    "http://localhost:3000/d/sol-managed-resource-rds?var-resource=acme-prod-postgres"
    url
;;

let test_dashboard_resource_scope_no_workspace_var () =
  let url =
    ok_url
      (O.url
         ~base_url
         ~workspace
         ~kind:O.Dashboard
         (O.Resource ("rds", "acme-prod-postgres")))
  in
  check_bool
    "no var-workspace (account/cluster-scoped, not per-workspace)"
    false
    (contains url "var-workspace")
;;

let test_dashboard_resource_scope_normalizes_type_and_name () =
  let url =
    ok_url
      (O.url
         ~base_url
         ~workspace
         ~kind:O.Dashboard
         (O.Resource ("RDS", "Acme_Prod_Postgres")))
  in
  check_bool
    "resource_type normalized into the dashboard uid"
    true
    (contains url "/d/sol-managed-resource-rds");
  check_bool
    "resource_name normalized into var-resource"
    true
    (contains url "var-resource=acme-prod-postgres")
;;

let test_metrics_matches_dashboard_for_resource_scope () =
  let dashboard =
    ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Resource ("rds", "postgres")))
  in
  let metrics =
    ok_url (O.url ~base_url ~workspace ~kind:O.Metrics (O.Resource ("rds", "postgres")))
  in
  check_string "metrics == dashboard target" dashboard metrics
;;

let test_dashboard_resource_scope_empty_type () =
  let result =
    O.url ~base_url ~workspace ~kind:O.Dashboard (O.Resource ("", "postgres"))
  in
  check_bool "empty resource type -> Error" true (String.length (err_msg result) > 0)
;;

let test_dashboard_resource_scope_empty_name () =
  let result = O.url ~base_url ~workspace ~kind:O.Dashboard (O.Resource ("rds", "")) in
  check_bool "empty resource name -> Error" true (String.length (err_msg result) > 0)
;;

let test_logs_resource_scope_has_no_view () =
  let result = O.url ~base_url ~workspace ~kind:O.Logs (O.Resource ("rds", "postgres")) in
  check_bool
    "no logs view for managed resources -> Error"
    true
    (String.length (err_msg result) > 0)
;;

let test_logs_workspace_scope () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Logs O.Workspace) in
  check_bool "explore url" true (contains url "/explore");
  check_bool "selects on the workspace identity label" true (contains url "myapp");
  check_bool "no namespace selector" false (contains url "namespace")
;;

let test_logs_domain_scope () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Logs (O.Domain "payments")) in
  check_bool "explore url" true (contains url "/explore");
  check_bool "carries the workspace label" true (contains url "myapp");
  check_bool "carries the domain label" true (contains url "payments");
  check_bool "no namespace selector" false (contains url "namespace")
;;

let test_logs_service_scope () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Logs (O.Service ("payments", "charge_svc")))
  in
  check_bool "explore url" true (contains url "/explore");
  check_bool "k8s name normalized" true (contains url "charge-svc");
  check_bool "no namespace selector" false (contains url "namespace")
;;

let test_logs_service_scope_invalid_name () =
  let result = O.url ~base_url ~workspace ~kind:O.Logs (O.Service ("payments", "")) in
  check_bool "empty service name -> Error" true (String.length (err_msg result) > 0)
;;

let test_infra_url_is_the_target_infrastructure_dashboard () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Infra O.Workspace) in
  check_string
    "the infra view opens the target-infrastructure dashboard"
    "http://localhost:3000/d/sol-target-infrastructure"
    url
;;

let test_infra_takes_no_scope () =
  let result = O.url ~base_url ~workspace ~kind:O.Infra (O.Domain "payments") in
  check_bool
    "a scope is refused"
    true
    (contains (err_msg result) "target-scoped"
     && contains (err_msg result) "no application scope")
;;

let test_infra_requires_a_target () =
  check_bool "the infra view is target-addressed" true (O.requires_target O.Infra);
  check_bool "logs is not" false (O.requires_target O.Logs);
  check_bool "metrics is not" false (O.requires_target O.Metrics);
  check_bool "dashboard is not" false (O.requires_target O.Dashboard);
  check_bool
    "no target is refused, naming the view"
    true
    (match O.validate ~kind:O.Infra ~target_present:false O.Workspace with
     | Error message -> contains message "--target" && contains message "infra"
     | Ok () -> false);
  check_bool
    "a target and no scope is accepted"
    true
    (O.validate ~kind:O.Infra ~target_present:true O.Workspace = Ok ());
  check_bool
    "a scope is refused before the target is looked at"
    true
    (match
       O.validate
         ~kind:O.Infra
         ~target_present:true
         (O.Service ("payments", "charge-svc"))
     with
     | Error message -> contains message "no application scope"
     | Ok () -> false);
  check_bool
    "the scope-addressed views are untouched"
    true
    (O.validate ~kind:O.Logs ~target_present:false O.Workspace = Ok ()
     && O.validate ~kind:O.Dashboard ~target_present:false (O.Domain "payments") = Ok ())
;;

let test_provider_console_urls_are_provider_owned () =
  let target ~provider ~region ~fields : Sol_cli_config.target =
    { name = "prod/" ^ Sol_cli_provider.to_string provider ^ "/" ^ region
    ; env = "prod"
    ; provider
    ; region
    ; registry = None
    ; base_domain = None
    ; cluster_issuer = None
    ; letsencrypt_email = None
    ; cluster_name = None
    ; kube_context = None
    ; kubeconfig = None
    ; terraform_var_file = None
    ; observability_backend = None
    ; destroy_retention = None
    ; alert_receiver_type = None
    ; alert_receiver_url = None
    ; alert_owner = None
    ; alert_runbook_url = None
    ; state_bucket = None
    ; cluster_endpoint_cidr = None
    ; dns_zone_ownership = None
    ; node_failure_headroom_nodes = None
    ; profile = None
    ; provider_fields = fields
    }
  in
  (match
     Sol_cli_provider_capabilities.provider_console_url
       (target ~provider:Sol_cli_provider.Aws ~region:"us-east-1" ~fields:[])
   with
   | Some url ->
     check_bool "the AWS console names the region" true (contains url "region=us-east-1")
   | None -> Alcotest.fail "an AWS target must have a console");
  (match
     Sol_cli_provider_capabilities.provider_console_url
       (target
          ~provider:Sol_cli_provider.Gcp
          ~region:"us-central1"
          ~fields:[ "gcp", [ "project_id", "sol-qualification" ] ])
   with
   | Some url ->
     check_bool
       "the GCP console names the project"
       true
       (contains url "project=sol-qualification")
   | None -> Alcotest.fail "a GCP target with a project must have a console");
  check_bool
    "a GCP target with no project has no console to offer"
    true
    (Sol_cli_provider_capabilities.provider_console_url
       (target ~provider:Sol_cli_provider.Gcp ~region:"us-central1" ~fields:[])
     = None)
;;

let () =
  Alcotest.run
    "open"
    [ ( "parse_scope"
      , [ Alcotest.test_case "none -> workspace" `Quick test_parse_scope_none
        ; Alcotest.test_case "domain only" `Quick test_parse_scope_domain
        ; Alcotest.test_case "domain/service" `Quick test_parse_scope_domain_service
        ; Alcotest.test_case "too many segments" `Quick test_parse_scope_too_many_segments
        ; Alcotest.test_case "resource/<type>/<name>" `Quick test_parse_scope_resource
        ] )
    ; ( "url dashboard/metrics"
      , [ Alcotest.test_case "workspace scope" `Quick test_dashboard_workspace_scope
        ; Alcotest.test_case "domain scope" `Quick test_dashboard_domain_scope
        ; Alcotest.test_case "service scope" `Quick test_dashboard_service_scope
        ; Alcotest.test_case "metrics == dashboard" `Quick test_metrics_matches_dashboard
        ; Alcotest.test_case
            "service scope normalizes underscore name"
            `Quick
            test_dashboard_service_scope_normalizes_underscore_name
        ; Alcotest.test_case
            "domain scope normalizes case/underscore"
            `Quick
            test_dashboard_domain_scope_normalizes_case_and_underscore
        ; Alcotest.test_case
            "workspace scope normalizes case/underscore"
            `Quick
            test_dashboard_workspace_scope_normalizes_case_and_underscore
        ; Alcotest.test_case
            "domain scope normalizes internal space"
            `Quick
            test_dashboard_domain_scope_normalizes_internal_space
        ; Alcotest.test_case
            "invalid service name -> Error"
            `Quick
            test_dashboard_service_scope_invalid_name
        ] )
    ; ( "url dashboard/metrics — resource scope (OBS-044)"
      , [ Alcotest.test_case "resource scope" `Quick test_dashboard_resource_scope
        ; Alcotest.test_case
            "no var-workspace"
            `Quick
            test_dashboard_resource_scope_no_workspace_var
        ; Alcotest.test_case
            "normalizes type/name"
            `Quick
            test_dashboard_resource_scope_normalizes_type_and_name
        ; Alcotest.test_case
            "metrics == dashboard"
            `Quick
            test_metrics_matches_dashboard_for_resource_scope
        ; Alcotest.test_case
            "empty resource type -> Error"
            `Quick
            test_dashboard_resource_scope_empty_type
        ; Alcotest.test_case
            "empty resource name -> Error"
            `Quick
            test_dashboard_resource_scope_empty_name
        ] )
    ; ( "url logs"
      , [ Alcotest.test_case "workspace scope" `Quick test_logs_workspace_scope
        ; Alcotest.test_case "domain scope" `Quick test_logs_domain_scope
        ; Alcotest.test_case "service scope" `Quick test_logs_service_scope
        ; Alcotest.test_case
            "invalid service name"
            `Quick
            test_logs_service_scope_invalid_name
        ; Alcotest.test_case
            "resource scope has no logs view"
            `Quick
            test_logs_resource_scope_has_no_view
        ] )
    ; ( "url infra (INFRA-027)"
      , [ Alcotest.test_case
            "the target-infrastructure dashboard"
            `Quick
            test_infra_url_is_the_target_infrastructure_dashboard
        ; Alcotest.test_case "takes no scope" `Quick test_infra_takes_no_scope
        ; Alcotest.test_case
            "requires a target and rejects a scope"
            `Quick
            test_infra_requires_a_target
        ; Alcotest.test_case
            "provider console URLs are provider-owned"
            `Quick
            test_provider_console_urls_are_provider_owned
        ] )
    ]
;;
