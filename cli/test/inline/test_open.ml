let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

module O = Sol_cli_open

let contains url sub = Sol_cli_string.contains ~needle:sub url

let ok_url = function
  | Ok s -> s
  | Error msg -> Windtrap.fail ("expected Ok, got Error " ^ msg)
;;

let err_msg = function
  | Ok s -> Windtrap.fail ("expected Error, got Ok " ^ s)
  | Error msg -> msg
;;

let percent_decode s =
  let hex c =
    match c with
    | '0' .. '9' -> Char.code c - Char.code '0'
    | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
    | _ -> -1
  in
  let buf = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n
    then
      if s.[i] = '%' && i + 2 < n && hex s.[i + 1] >= 0 && hex s.[i + 2] >= 0
      then (
        Buffer.add_char buf (Char.chr ((hex s.[i + 1] * 16) + hex s.[i + 2]));
        go (i + 3))
      else (
        Buffer.add_char buf s.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents buf
;;

let grafana_pane url =
  let marker = "left=" in
  let n = String.length url
  and m = String.length marker in
  let rec find i =
    if i + m > n
    then Windtrap.fail "the url has no left= pane"
    else if String.sub url i m = marker
    then i + m
    else find (i + 1)
  in
  let start = find 0 in
  try Yojson.Safe.from_string (percent_decode (String.sub url start (n - start))) with
  | _ -> Windtrap.fail ("the left= pane is not valid JSON: " ^ url)
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

let test_traces_workspace_scope () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Traces O.Workspace) in
  check_bool "explore url" true (contains url "/explore");
  check_bool
    "names the tempo datasource"
    true
    (contains url "%22datasource%22%3A%22tempo%22");
  check_bool
    "asks for a traceql query"
    true
    (contains url "%22queryType%22%3A%22traceql%22");
  check_bool "selects on resource.workspace" true (contains url "resource.workspace");
  check_bool "carries the workspace identity" true (contains url "myapp");
  check_bool "no raw brace in the url" false (contains url "{");
  check_bool "no raw double quote in the url" false (contains url {|"|});
  check_bool "no raw space in the url" false (contains url " ")
;;

let test_traces_domain_scope () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Traces (O.Domain "payments")) in
  check_bool "selects on resource.domain" true (contains url "resource.domain");
  check_bool "carries the workspace identity" true (contains url "myapp");
  check_bool "carries the domain identity" true (contains url "payments");
  check_bool
    "no service selector for a domain scope"
    false
    (contains url "resource.service")
;;

let test_traces_service_scope () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Traces (O.Service ("payments", "charge_svc")))
  in
  check_bool "selects on resource.service" true (contains url "resource.service");
  check_bool "k8s name normalized" true (contains url "charge-svc");
  check_bool "no raw underscore in the query" false (contains url "charge_svc")
;;

let test_traces_resource_scope_has_no_view () =
  let result =
    O.url ~base_url ~workspace ~kind:O.Traces (O.Resource ("rds", "postgres"))
  in
  check_bool
    "no traces view for managed resources -> Error"
    true
    (contains (err_msg result) "no traces view")
;;

let test_traces_requires_no_target () =
  check_bool
    "traces is scope-addressed, not target-addressed"
    false
    (O.requires_target O.Traces);
  check_bool
    "traces accepts every application scope without a target"
    true
    (O.validate ~kind:O.Traces ~target_present:false O.Workspace = Ok ()
     && O.validate ~kind:O.Traces ~target_present:false (O.Domain "payments") = Ok ()
     && O.validate
          ~kind:O.Traces
          ~target_present:false
          (O.Service ("payments", "charge-svc"))
        = Ok ())
;;

let test_traces_url_pane_round_trips () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Traces (O.Service ("payments", "charge_svc")))
  in
  let pane = grafana_pane url in
  let open Yojson.Safe.Util in
  check_string
    "pane names the tempo datasource"
    "tempo"
    (pane |> member "datasource" |> to_string);
  let query = pane |> member "queries" |> index 0 in
  check_string "pane asks for traceql" "traceql" (query |> member "queryType" |> to_string);
  check_string
    "the query survives the url round trip, quotes intact"
    {|{ resource.workspace = "myapp" && resource.domain = "payments" && resource.service = "charge-svc" }|}
    (query |> member "query" |> to_string)
;;

let test_logs_url_pane_round_trips () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Logs (O.Domain "payments")) in
  let pane = grafana_pane url in
  let open Yojson.Safe.Util in
  check_string
    "pane names the loki datasource"
    "loki"
    (pane |> member "datasource" |> to_string);
  let query = pane |> member "queries" |> index 0 in
  check_string
    "the logql survives the url round trip, quotes intact"
    {|{workspace="myapp", domain="payments"}|}
    (query |> member "expr" |> to_string)
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
   | None -> Windtrap.fail "an AWS target must have a console");
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
   | None -> Windtrap.fail "a GCP target with a project must have a console");
  check_bool
    "a GCP target with no project has no console to offer"
    true
    (Sol_cli_provider_capabilities.provider_console_url
       (target ~provider:Sol_cli_provider.Gcp ~region:"us-central1" ~fields:[])
     = None)
;;

let%test "parse_scope: none -> workspace" = test_parse_scope_none ()
let%test "parse_scope: domain only" = test_parse_scope_domain ()
let%test "parse_scope: domain/service" = test_parse_scope_domain_service ()
let%test "parse_scope: too many segments" = test_parse_scope_too_many_segments ()
let%test "parse_scope: resource/<type>/<name>" = test_parse_scope_resource ()
let%test "url dashboard/metrics: workspace scope" = test_dashboard_workspace_scope ()
let%test "url dashboard/metrics: domain scope" = test_dashboard_domain_scope ()
let%test "url dashboard/metrics: service scope" = test_dashboard_service_scope ()
let%test "url dashboard/metrics: metrics == dashboard" = test_metrics_matches_dashboard ()

let%test "url dashboard/metrics: service scope normalizes underscore name" =
  test_dashboard_service_scope_normalizes_underscore_name ()
;;

let%test "url dashboard/metrics: domain scope normalizes case/underscore" =
  test_dashboard_domain_scope_normalizes_case_and_underscore ()
;;

let%test "url dashboard/metrics: workspace scope normalizes case/underscore" =
  test_dashboard_workspace_scope_normalizes_case_and_underscore ()
;;

let%test "url dashboard/metrics: domain scope normalizes internal space" =
  test_dashboard_domain_scope_normalizes_internal_space ()
;;

let%test "url dashboard/metrics: invalid service name -> Error" =
  test_dashboard_service_scope_invalid_name ()
;;

let%test "url dashboard/metrics — resource scope (OBS-044): resource scope" =
  test_dashboard_resource_scope ()
;;

let%test "url dashboard/metrics — resource scope (OBS-044): no var-workspace" =
  test_dashboard_resource_scope_no_workspace_var ()
;;

let%test "url dashboard/metrics — resource scope (OBS-044): normalizes type/name" =
  test_dashboard_resource_scope_normalizes_type_and_name ()
;;

let%test "url dashboard/metrics — resource scope (OBS-044): metrics == dashboard" =
  test_metrics_matches_dashboard_for_resource_scope ()
;;

let%test "url dashboard/metrics — resource scope (OBS-044): empty resource type -> Error" =
  test_dashboard_resource_scope_empty_type ()
;;

let%test "url dashboard/metrics — resource scope (OBS-044): empty resource name -> Error" =
  test_dashboard_resource_scope_empty_name ()
;;

let%test "url logs: workspace scope" = test_logs_workspace_scope ()
let%test "url logs: domain scope" = test_logs_domain_scope ()
let%test "url logs: service scope" = test_logs_service_scope ()
let%test "url logs: invalid service name" = test_logs_service_scope_invalid_name ()

let%test "url logs: resource scope has no logs view" =
  test_logs_resource_scope_has_no_view ()
;;

let%test "url traces (OBS-045): workspace scope" = test_traces_workspace_scope ()
let%test "url traces (OBS-045): domain scope" = test_traces_domain_scope ()
let%test "url traces (OBS-045): service scope" = test_traces_service_scope ()

let%test "url traces (OBS-045): resource scope has no view" =
  test_traces_resource_scope_has_no_view ()
;;

let%test "url traces (OBS-045): scope-addressed, needs no target" =
  test_traces_requires_no_target ()
;;

let%test "url traces (OBS-045): the pane is valid JSON and round-trips" =
  test_traces_url_pane_round_trips ()
;;

let%test "url logs: the pane is valid JSON and round-trips" =
  test_logs_url_pane_round_trips ()
;;

let%test "url infra (INFRA-027): the target-infrastructure dashboard" =
  test_infra_url_is_the_target_infrastructure_dashboard ()
;;

let%test "url infra (INFRA-027): takes no scope" = test_infra_takes_no_scope ()

let%test "url infra (INFRA-027): requires a target and rejects a scope" =
  test_infra_requires_a_target ()
;;

let%test "url infra (INFRA-027): provider console URLs are provider-owned" =
  test_provider_console_urls_are_provider_owned ()
;;
