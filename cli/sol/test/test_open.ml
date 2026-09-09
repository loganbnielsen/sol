let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

module O = Sol_cli_open

let contains url sub =
  let re = Str.regexp_string sub in
  try
    ignore (Str.search_forward re url 0);
    true
  with Not_found -> false

let ok_url = function
  | Ok s -> s
  | Error msg -> Alcotest.fail ("expected Ok, got Error " ^ msg)

let err_msg = function
  | Ok s -> Alcotest.fail ("expected Error, got Ok " ^ s)
  | Error msg -> msg

(* ── parse_scope ─────────────────────────────────────────────────────────── *)

let test_parse_scope_none () =
  check_bool "None -> Workspace" true (O.parse_scope None = Ok O.Workspace)

let test_parse_scope_domain () =
  check_bool "domain only" true
    (O.parse_scope (Some "payments") = Ok (O.Domain "payments"))

let test_parse_scope_domain_service () =
  check_bool "domain/service" true
    (O.parse_scope (Some "payments/charge-svc")
    = Ok (O.Service ("payments", "charge-svc")))

let test_parse_scope_too_many_segments () =
  check_bool "extra slash -> Error" true
    (match O.parse_scope (Some "a/b/c") with Error _ -> true | Ok _ -> false)

let test_parse_scope_resource () =
  check_bool "resource/<type>/<name>" true
    (O.parse_scope (Some "resource/rds/acme-prod-postgres")
    = Ok (O.Resource ("rds", "acme-prod-postgres")))

(* ── url: dashboard / metrics (share a target) ──────────────────────────── *)

let base_url = "http://localhost:3000"
let workspace = "myapp"

let test_dashboard_workspace_scope () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard O.Workspace) in
  check_string "workspace dashboard"
    "http://localhost:3000/d/sol-workspace-overview?var-workspace=myapp" url

let test_dashboard_domain_scope () =
  let url =
    ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Domain "payments"))
  in
  check_bool "uses service-template uid" true
    (contains url "/d/sol-service-template");
  check_bool "presets var-workspace" true (contains url "var-workspace=myapp");
  check_bool "presets var-domain" true (contains url "var-domain=payments");
  check_bool "no var-service" false (contains url "var-service")

let test_dashboard_service_scope () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Dashboard
         (O.Service ("payments", "charge-svc")))
  in
  check_bool "presets var-workspace" true (contains url "var-workspace=myapp");
  check_bool "presets var-domain" true (contains url "var-domain=payments");
  check_bool "presets var-service" true (contains url "var-service=charge-svc")

let test_dashboard_workspace_scope_normalizes_case_and_underscore () =
  let url =
    ok_url (O.url ~base_url ~workspace:"My_App" ~kind:O.Dashboard O.Workspace)
  in
  check_bool "var-workspace uses the normalized (lowercase, hyphenated) name"
    true
    (contains url "var-workspace=my-app")

let test_metrics_matches_dashboard () =
  let dashboard =
    ok_url (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Domain "payments"))
  in
  let metrics =
    ok_url (O.url ~base_url ~workspace ~kind:O.Metrics (O.Domain "payments"))
  in
  check_string "metrics == dashboard target" dashboard metrics

(* Regression: dashboard_url used to pass scope strings through unchanged,
   while logs_url already normalized them -- 'sol open dashboard
   payments/charge_svc' presented a var-service value ("charge_svc") that
   never matched any metric's normalized 'service' label ("charge-svc"),
   so the dashboard opened empty. *)
let test_dashboard_service_scope_normalizes_underscore_name () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Dashboard
         (O.Service ("payments", "charge_svc")))
  in
  check_bool "var-service uses the normalized (hyphenated) name" true
    (contains url "var-service=charge-svc")

let test_dashboard_domain_scope_normalizes_case_and_underscore () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Domain "Payments_Team"))
  in
  check_bool "var-domain uses the normalized (lowercase, hyphenated) name" true
    (contains url "var-domain=payments-team")

(* OBS-021: sanitize_label_value handles arbitrary invalid characters
   (spaces, etc.), not just underscore -- a workspace directory name like
   "My App" used to survive un-mangled past the old normalize-only call. *)
let test_dashboard_domain_scope_normalizes_internal_space () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Dashboard (O.Domain "Payments Team"))
  in
  check_bool "var-domain replaces the internal space" true
    (contains url "var-domain=payments-team")

let test_dashboard_service_scope_invalid_name () =
  let result =
    O.url ~base_url ~workspace ~kind:O.Dashboard (O.Service ("payments", ""))
  in
  check_bool "empty service name -> Error" true
    (String.length (err_msg result) > 0)

(* ── url: dashboard / metrics — managed resource scope (OBS-044) ─────────── *)

let test_dashboard_resource_scope () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Dashboard
         (O.Resource ("rds", "acme-prod-postgres")))
  in
  check_string "managed resource dashboard"
    "http://localhost:3000/d/sol-managed-resource-rds?var-resource=acme-prod-postgres"
    url

let test_dashboard_resource_scope_no_workspace_var () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Dashboard
         (O.Resource ("rds", "acme-prod-postgres")))
  in
  check_bool "no var-workspace (account/cluster-scoped, not per-workspace)"
    false
    (contains url "var-workspace")

let test_dashboard_resource_scope_normalizes_type_and_name () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Dashboard
         (O.Resource ("RDS", "Acme_Prod_Postgres")))
  in
  check_bool "resource_type normalized into the dashboard uid" true
    (contains url "/d/sol-managed-resource-rds");
  check_bool "resource_name normalized into var-resource" true
    (contains url "var-resource=acme-prod-postgres")

let test_metrics_matches_dashboard_for_resource_scope () =
  let dashboard =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Dashboard
         (O.Resource ("rds", "postgres")))
  in
  let metrics =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Metrics
         (O.Resource ("rds", "postgres")))
  in
  check_string "metrics == dashboard target" dashboard metrics

let test_dashboard_resource_scope_empty_type () =
  let result =
    O.url ~base_url ~workspace ~kind:O.Dashboard (O.Resource ("", "postgres"))
  in
  check_bool "empty resource type -> Error" true
    (String.length (err_msg result) > 0)

let test_dashboard_resource_scope_empty_name () =
  let result =
    O.url ~base_url ~workspace ~kind:O.Dashboard (O.Resource ("rds", ""))
  in
  check_bool "empty resource name -> Error" true
    (String.length (err_msg result) > 0)

let test_logs_resource_scope_has_no_view () =
  let result =
    O.url ~base_url ~workspace ~kind:O.Logs (O.Resource ("rds", "postgres"))
  in
  check_bool "no logs view for managed resources -> Error" true
    (String.length (err_msg result) > 0)

(* ── url: logs ───────────────────────────────────────────────────────────── *)

let test_logs_workspace_scope () =
  let url = ok_url (O.url ~base_url ~workspace ~kind:O.Logs O.Workspace) in
  check_bool "explore url" true (contains url "/explore");
  check_bool "scoped to workspace namespaces" true (contains url "myapp")

let test_logs_domain_scope () =
  let url =
    ok_url (O.url ~base_url ~workspace ~kind:O.Logs (O.Domain "payments"))
  in
  check_bool "explore url" true (contains url "/explore")

let test_logs_service_scope () =
  let url =
    ok_url
      (O.url ~base_url ~workspace ~kind:O.Logs
         (O.Service ("payments", "charge_svc")))
  in
  check_bool "explore url" true (contains url "/explore");
  (* charge_svc gets normalized to its k8s (hyphenated) name *)
  check_bool "k8s name normalized" true (contains url "charge-svc")

let test_logs_service_scope_invalid_name () =
  let result =
    O.url ~base_url ~workspace ~kind:O.Logs (O.Service ("payments", ""))
  in
  check_bool "empty service name -> Error" true
    (String.length (err_msg result) > 0)

let () =
  Alcotest.run "open"
    [
      ( "parse_scope",
        [
          Alcotest.test_case "none -> workspace" `Quick test_parse_scope_none;
          Alcotest.test_case "domain only" `Quick test_parse_scope_domain;
          Alcotest.test_case "domain/service" `Quick
            test_parse_scope_domain_service;
          Alcotest.test_case "too many segments" `Quick
            test_parse_scope_too_many_segments;
          Alcotest.test_case "resource/<type>/<name>" `Quick
            test_parse_scope_resource;
        ] );
      ( "url dashboard/metrics",
        [
          Alcotest.test_case "workspace scope" `Quick
            test_dashboard_workspace_scope;
          Alcotest.test_case "domain scope" `Quick test_dashboard_domain_scope;
          Alcotest.test_case "service scope" `Quick test_dashboard_service_scope;
          Alcotest.test_case "metrics == dashboard" `Quick
            test_metrics_matches_dashboard;
          Alcotest.test_case "service scope normalizes underscore name" `Quick
            test_dashboard_service_scope_normalizes_underscore_name;
          Alcotest.test_case "domain scope normalizes case/underscore" `Quick
            test_dashboard_domain_scope_normalizes_case_and_underscore;
          Alcotest.test_case "workspace scope normalizes case/underscore" `Quick
            test_dashboard_workspace_scope_normalizes_case_and_underscore;
          Alcotest.test_case "domain scope normalizes internal space" `Quick
            test_dashboard_domain_scope_normalizes_internal_space;
          Alcotest.test_case "invalid service name -> Error" `Quick
            test_dashboard_service_scope_invalid_name;
        ] );
      ( "url dashboard/metrics — resource scope (OBS-044)",
        [
          Alcotest.test_case "resource scope" `Quick
            test_dashboard_resource_scope;
          Alcotest.test_case "no var-workspace" `Quick
            test_dashboard_resource_scope_no_workspace_var;
          Alcotest.test_case "normalizes type/name" `Quick
            test_dashboard_resource_scope_normalizes_type_and_name;
          Alcotest.test_case "metrics == dashboard" `Quick
            test_metrics_matches_dashboard_for_resource_scope;
          Alcotest.test_case "empty resource type -> Error" `Quick
            test_dashboard_resource_scope_empty_type;
          Alcotest.test_case "empty resource name -> Error" `Quick
            test_dashboard_resource_scope_empty_name;
        ] );
      ( "url logs",
        [
          Alcotest.test_case "workspace scope" `Quick test_logs_workspace_scope;
          Alcotest.test_case "domain scope" `Quick test_logs_domain_scope;
          Alcotest.test_case "service scope" `Quick test_logs_service_scope;
          Alcotest.test_case "invalid service name" `Quick
            test_logs_service_scope_invalid_name;
          Alcotest.test_case "resource scope has no logs view" `Quick
            test_logs_resource_scope_has_no_view;
        ] );
    ]
