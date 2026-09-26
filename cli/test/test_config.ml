let check_str = Alcotest.(check string)
let check_strs = Alcotest.(check (list string))
let check_int_opt = Alcotest.(check (option int))
let check_bool = Alcotest.(check bool)
let check_str_opt = Alcotest.(check (option string))

let check_provider label expected provider =
  check_str label expected (Sol_cli_provider.to_string provider)
;;

let only_index indexes =
  match indexes with
  | [ index ] -> index
  | _ -> Alcotest.fail "expected one index"
;;

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let mkdir_p path =
  let parts = String.split_on_char '/' path in
  let rec loop current = function
    | [] -> ()
    | part :: rest ->
      let next = if current = "" then part else Filename.concat current part in
      (try Unix.mkdir next 0o755 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      loop next rest
  in
  loop "" parts
;;

let with_temp_dir f =
  let dir = Filename.temp_file "sol-config-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       f ())
;;

let with_chdir dir f =
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       f ())
;;

let expect_load_error expected =
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Ok _ -> Alcotest.fail "expected load_for_target to fail"
  | Error e -> check_str "message" expected e.message
;;

(* REFAC-106: a YAML syntax error is libyaml's, prefixed, and names its line. *)
let expect_yaml_error () =
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Ok _ -> Alcotest.fail "expected a YAML syntax error"
  | Error e ->
    let prefix = "invalid YAML: " in
    check_str
      "prefix"
      prefix
      (String.sub e.message 0 (min (String.length e.message) (String.length prefix)));
    Alcotest.(check bool) "names a line" true (e.line > 0)
;;

let example_pluto_dir () =
  if Sys.file_exists "examples/pluto/sol.yml"
  then "examples/pluto"
  else "../../../../examples/pluto"
;;

let write_base () =
  write
    "sol.yml"
    {|
project: pluto

resources:
  app_db:
    type: postgres

  sessions:
    type: dynamodb
    partition_key: user_id
    sort_key: session_id
    indexes:
      by_expires_at:
        partition_key: tenant_id
        sort_key: expires_at

services:
  api:
    type: http
    path: app/core/api
    uses: [app_db, sessions]
|}
;;

let test_target_path_supplies_placement () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: pluto-prod
  base_domain: pluto.example.com
  cluster_issuer: letsencrypt-staging
  letsencrypt_email: ops@pluto.example.com

services:
  api:
    scale:
      min: 2
      max: 10
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      check_str "project" "pluto" (Option.get cfg.Sol_cli_config.project);
      let target = cfg.Sol_cli_config.target in
      check_str "target name" "prod/aws/us-east-1" target.name;
      check_str "env" "prod" target.env;
      check_provider "provider" "aws" target.provider;
      check_str "region" "us-east-1" target.region;
      check_str "cluster" "pluto-prod" (Option.get target.cluster_name);
      check_str "cluster issuer" "letsencrypt-staging" (Option.get target.cluster_issuer);
      check_str
        "Let's Encrypt email"
        "ops@pluto.example.com"
        (Option.get target.letsencrypt_email);
      let resource = List.hd (Sol_cli_config.resources cfg) in
      check_str "resource" "app_db" resource.name;
      let service = List.hd (Sol_cli_config.services cfg) in
      check_str "service" "api" service.name;
      check_strs "uses" [ "app_db"; "sessions" ] service.uses;
      check_int_opt "scale min" (Some 2) service.scale_min;
      check_int_opt "scale max" (Some 10) service.scale_max)
;;

let test_duplicate_resource_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    type: postgres
  app_db:
    type: dynamodb
|};
    expect_load_error "duplicate resource \"app_db\"")
;;

let test_unknown_key_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    typo: nope
|};
    expect_load_error "unknown service key \"typo\"")
;;

(* FEAT-088: the explicit, language-neutral compatibility input. *)
let test_service_language_parses () =
  with_temp_dir (fun () ->
    write "sol.yml" "services:\n  api:\n    language: ocaml\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_bool
        "language parsed"
        true
        (service.Sol_cli_config.language = Some Sol_cli_compat.Ocaml))
;;

let test_unknown_service_language_fails () =
  with_temp_dir (fun () ->
    write "sol.yml" "services:\n  api:\n    language: rust\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Alcotest.fail "expected an unknown language to fail"
    | Error e ->
      check_bool
        "names the supported languages"
        true
        (Sol_cli_string.contains ~needle:"supported: ocaml, typescript" e.message))
;;

let test_duplicate_top_level_section_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    type: postgres

services:
  api:
    type: http

resources:
  sessions:
    type: dynamodb
|};
    expect_load_error "duplicate top-level section \"resources\"")
;;

let test_duplicate_index_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  sessions:
    type: dynamodb
    indexes:
      by_expires_at:
      by_expires_at:
|};
    expect_load_error "duplicate index \"by_expires_at\"")
;;

let test_malformed_list_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [app_db
|};
    expect_yaml_error ())
;;

let test_malformed_quoted_scalar_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    path: "app/core/api
|};
    expect_yaml_error ())
;;

let test_malformed_quoted_list_item_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: ["app_db]
|};
    expect_yaml_error ())
;;

let test_undeclared_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [missing]
|};
    expect_load_error "service \"api\" uses undeclared resource \"missing\"")
;;

let test_absolute_cross_region_uses_ref_parses () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/us-east-1/analytics_db]
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_strs "uses" [ "/us-east-1/analytics_db" ] service.uses;
      check_str
        "formatted use"
        "/us-east-1/analytics_db (cross-region)"
        (Sol_cli_config.format_use_ref (List.hd service.uses)))
;;

let test_cross_provider_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/gcp/us-central1/analytics_db]
|};
    expect_load_error "cross-provider uses refs are not supported in v1")
;;

let test_cross_env_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/prod/aws/us-east-1/analytics_db]
|};
    expect_load_error "cross-env uses refs are not supported in v1")
;;

let test_three_segment_cross_env_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/prod/us-east-1/analytics_db]
|};
    expect_load_error "cross-env uses refs are not supported in v1")
;;

let test_two_segment_cross_provider_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/gcp/analytics_db]
|};
    expect_load_error "cross-provider uses refs are not supported in v1")
;;

let test_empty_segment_uses_ref_fails_to_parse () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/us-east-1//analytics_db]
|};
    expect_load_error "absolute uses ref must look like /<region>/<resource>")
;;

let test_omitted_resource_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    type: postgres

services:
  api:
    uses: [app_db]
|};
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
resources:
  app_db:
    omit: true
|};
    expect_load_error "service \"api\" uses undeclared resource \"app_db\"")
;;

let test_resource_key_after_indexes_parses () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  sessions:
    type: dynamodb
    indexes:
      by_expires_at:
    size: small
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let resource = List.hd (Sol_cli_config.resources cfg) in
      check_str_opt "size" (Some "small") resource.size)
;;

let test_service_key_after_scale_parses () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    scale:
      min: 1
    path: app/core/api
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_str_opt "path" (Some "app/core/api") service.path)
;;

let test_nested_provider_box_still_tolerated () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc:
      id: vpc-123
  registry: registry.example.com
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_str_opt "registry" (Some "registry.example.com") target.registry)
;;

let test_target_provider_box_ends_before_generic_key () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    account_id: "123456789012"
  registry: registry.example.com
    typo: nope
|};
    expect_yaml_error ())
;;

let test_empty_target_value_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  registry:
|};
    expect_load_error "missing value for registry")
;;

let test_target_after_resources_parses () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    type: postgres

target:
  registry: registry.example.com
|};
    (* REFAC-106: key order is not meaningful in YAML. *)
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      check_str
        "registry"
        "registry.example.com"
        (Option.value cfg.Sol_cli_config.target.registry ~default:"<none>"))
;;

let test_quoted_hash_survives () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    type: http
    path: "app/core/api#1"
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_str_opt "path" (Some "app/core/api#1") service.path)
;;

let test_single_quoted_hash_survives () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    type: http
    path: 'app/core/api#1'
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_str_opt "path" (Some "app/core/api#1") service.path)
;;

let test_malformed_int_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    scale:
      min: abc
|};
    expect_load_error "expected integer for min")
;;

let test_malformed_bool_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    omit: TRUE
|};
    expect_load_error "expected true or false for omit")
;;

let test_target_overlay_can_omit_resources_and_services () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      {|
target:
  cluster_name: sol-dev

resources:
  app_db:
    omit: true

services:
  api:
    omit: true
|};
    match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let resource_names =
        Sol_cli_config.resources cfg
        |> List.map (fun (r : Sol_cli_config.resource) -> r.name)
      in
      let service_names =
        Sol_cli_config.services cfg
        |> List.map (fun (s : Sol_cli_config.service) -> s.name)
      in
      check_strs "resources" [ "sessions" ] resource_names;
      check_strs "services" [] service_names)
;;

let test_target_observability_backend_parsed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  base_domain: pluto.example.com
  observability_backend: self_hosted_durable
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_str
        "observability_backend"
        "self_hosted_durable"
        (Option.get target.observability_backend))
;;

(* OBS-043: the provider-neutral alert-delivery declaration. *)
let test_target_alert_delivery_parsed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  base_domain: pluto.example.com
  alert_receiver_type: webhook
  alert_receiver_url: https://hooks.example.com/sol-alerts
  alert_owner: payments-oncall
  alert_runbook_url: https://runbooks.example.com/sol
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_str "receiver type" "webhook" (Option.get target.alert_receiver_type);
      check_str
        "receiver url"
        "https://hooks.example.com/sol-alerts"
        (Option.get target.alert_receiver_url);
      check_str "owner" "payments-oncall" (Option.get target.alert_owner);
      check_str
        "runbook"
        "https://runbooks.example.com/sol"
        (Option.get target.alert_runbook_url))
;;

(* AUDIT-072: recoverable state and scoped identities are target declarations. *)
let test_target_recoverable_state_and_identities_parsed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  base_domain: pluto.example.com
  state_bucket: acme-tfstate
  aws:
    state_lock_table: acme-tflock
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
    deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
    operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
  cluster_endpoint_cidr: 203.0.113.0/24
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_str "state_bucket" "acme-tfstate" (Option.get target.state_bucket);
      check_str
        "state_lock_table"
        "acme-tflock"
        (Option.get (Sol_cli_config.provider_field target "state_lock_table"));
      check_str
        "provisioner_role_arn"
        "arn:aws:iam::111122223333:role/sol-provisioner"
        (Option.get (Sol_cli_config.provider_field target "provisioner_role_arn"));
      check_str
        "cluster_access_role_arn"
        "arn:aws:iam::111122223333:role/sol-cluster-access"
        (Option.get (Sol_cli_config.provider_field target "cluster_access_role_arn"));
      check_str
        "deploy_role_arn"
        "arn:aws:iam::111122223333:role/sol-deploy"
        (Option.get (Sol_cli_config.provider_field target "deploy_role_arn"));
      check_str
        "operator_role_arn"
        "arn:aws:iam::111122223333:role/sol-operator"
        (Option.get (Sol_cli_config.provider_field target "operator_role_arn"));
      check_str
        "cluster_endpoint_cidr"
        "203.0.113.0/24"
        (Option.get target.cluster_endpoint_cidr))
;;

let test_target_observability_backend_absent_when_unset () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      {|
target:
  cluster_name: sol-dev
|};
    match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_bool "observability_backend absent" true (target.observability_backend = None))
;;

let test_bad_target_path_fails () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"prod" with
    | Ok _ -> Alcotest.fail "expected invalid target path"
    | Error e ->
      check_str "message" "target must look like <env>/<provider>/<region>" e.message)
;;

let test_unknown_target_provider_fails () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"prod/azure/us-east-1" with
    | Ok _ -> Alcotest.fail "expected unknown target provider"
    | Error e -> check_str "message" "unsupported provider \"azure\"" e.message)
;;

let test_parent_target_path_fails () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"../../etc" with
    | Ok _ -> Alcotest.fail "expected invalid target path"
    | Error e -> check_str "message" "target path must not contain '..'" e.message)
;;

(* DEC-024 supersedes FEAT-026's "at least one of sol.yml or the target file"
   rule: a sol.yml is now the workspace boundary, so there is no such thing as
   a real target outside a workspace. Absence fails closed and names the fix;
   inside a workspace a target may legitimately rely on sol.yml alone
   (test_target_with_only_sol_yml_succeeds). *)
let test_target_outside_a_workspace_fails_closed () =
  with_temp_dir (fun () ->
    (* deliberately no write_base (), no sol.yml, no target file *)
    match Sol_cli_config.load_for_target ~target:"dev/aws/us-west-2" with
    | Ok _ -> Alcotest.fail "expected load_for_target to fail outside a workspace"
    | Error e ->
      check_bool
        "message names the fix"
        true
        (Sol_cli_string.contains ~needle:"sol new workspace" e.message))
;;

let test_target_with_only_sol_yml_succeeds () =
  with_temp_dir (fun () ->
    write_base ();
    (* prod/aws/us-east-1 has no sol/prod/aws/us-east-1.yml overlay --
       load_for_target itself stays permissive about that (only
       cmd_deploy.ml enforces the file must exist, for its own stronger
       mutating-cluster guarantee). *)
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail e.message
    | Ok _ -> ())
;;

let test_same_cluster_across_envs_fails () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      {|
target:
  cluster_name: shared
  kube_context: shared
|};
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: shared
  kube_context: shared
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Alcotest.fail "expected same-cluster envs to fail"
    | Error e ->
      assert (Sol_cli_string.contains ~needle:"dev" e.message);
      assert (Sol_cli_string.contains ~needle:"prod" e.message);
      assert (Sol_cli_string.contains ~needle:"shared" e.message))
;;

(* The lint compares the destination Sol will use, not the descriptive
   cluster_name. Here both targets *say* the same cluster_name while pointing at
   different contexts, which is two clusters — so this must succeed, and it is
   the case that would break if the lint went back to reading cluster_name. *)
let test_different_destinations_succeed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-west-2"
      {|
target:
  cluster_name: shared
  kube_context: shared-eu
|};
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: shared
  kube_context: shared-us
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok _ -> ())
;;

(* The destination is a function of the target. Nothing consults the machine's
   kubectl state, and the arguments the deploy will use come straight from the
   configured context. *)
let test_destination_comes_from_the_target () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  kube_context: sol-prod-us-east-1
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      (match Sol_cli_config.destination_of_target target with
       | Error message -> Alcotest.fail message
       | Ok destination ->
         Alcotest.(check string)
           "the context comes from the target"
           "sol-prod-us-east-1"
           destination.context;
         Alcotest.(check (list string))
           "and scopes the kubectl call"
           [ "--context"; "sol-prod-us-east-1" ]
           (Sol_cli_kube_destination.kubectl_args destination)))
;;

let test_destination_includes_scoped_kubeconfig () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  kube_context: sol-prod-us-east-1
  kubeconfig: .sol/kubeconfigs/prod-aws-us-east-1.kubeconfig
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      (match Sol_cli_config.destination_of_target target with
       | Error message -> Alcotest.fail message
       | Ok destination ->
         check_str_opt
           "the scoped kubeconfig comes from the target"
           (Some ".sol/kubeconfigs/prod-aws-us-east-1.kubeconfig")
           destination.kubeconfig;
         Alcotest.(check (list (pair string string)))
           "the child env scopes kubectl to that kubeconfig"
           [ "KUBECONFIG", ".sol/kubeconfigs/prod-aws-us-east-1.kubeconfig" ]
           (Sol_cli_kube_destination.environment destination)))
;;

(* An unconfigured destination fails closed rather than falling back to whatever
   kubectl is pointed at — the reason the field exists at all, and the property
   that keeps the ambient context out of the deploy path. *)
let test_destination_missing_fails_closed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: sol-prod
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      (match Sol_cli_config.destination_of_target target with
       | Ok destination ->
         Alcotest.fail
           (Printf.sprintf
              "expected a target with no context to fail closed, got %S"
              (Sol_cli_kube_destination.to_string destination))
       | Error message ->
         Alcotest.(check bool)
           "the error names the field to set"
           true
           (Sol_cli_string.contains ~needle:"kube_context" message)))
;;

let test_root_target_defaults_survive () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  registry: registry.example.com

services:
  api:
    type: http
|};
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: pluto-prod
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_str_opt "registry" (Some "registry.example.com") target.registry)
;;

let test_feat_028_shapes_still_tolerated () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    account_id: "123456789012"

resources:
  sessions:
    type: dynamodb
    indexes:
      by_expires_at:
        partition_key: tenant_id
        sort_key: expires_at
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_str "env" "prod" target.env;
      let resource = List.hd (Sol_cli_config.resources cfg) in
      let index = only_index resource.indexes in
      check_str "index" "by_expires_at" index.index_name;
      check_str_opt "index partition_key" (Some "tenant_id") index.partition_key;
      check_str_opt "index sort_key" (Some "expires_at") index.sort_key)
;;

let test_provider_box_round_trips () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
  gcp:
    project_id: pluto-dev
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_strs
        "aws fields"
        [ "vpc_cidr=10.42.0.0/16" ]
        (List.assoc "aws" target.provider_fields |> List.map (fun (k, v) -> k ^ "=" ^ v));
      check_strs
        "gcp fields"
        [ "project_id=pluto-dev" ]
        (List.assoc "gcp" target.provider_fields |> List.map (fun (k, v) -> k ^ "=" ^ v)))
;;

let test_duplicate_provider_box_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
  aws:
    account_id: "123456789012"
|};
    expect_load_error "duplicate target provider box \"aws\"")
;;

let test_unknown_provider_box_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  azure:
    subscription_id: pluto-dev
|};
    expect_load_error "unsupported provider \"azure\"")
;;

let test_provider_fields_feed_active_terraform_provider () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
  gcp:
    project_id: pluto-dev
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_bool "aws var present" true (List.mem ("vpc_cidr", "10.42.0.0/16") vars);
         check_bool "gcp var absent" false (List.mem ("project_id", "pluto-dev") vars)))
;;

(* DEC-033's `destroy_retention` reaches a target through `merge_target`, and the
   field was added to the type and the parser but not to the merge -- so a target
   file's `destroy_retention: none` was silently discarded and every destroy took
   the production default (retain the final snapshot). DEC-033's own tests build
   `target_empty` directly, so they never crossed the merge; this one does, on
   purpose, because "the setting is parsed" and "the setting arrives" are different
   claims and only the second one is the feature. *)
let test_destroy_retention_survives_the_merge () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  base_domain: example.test
|};
    mkdir_p "sol/prod/gcp";
    Targets_fixture.write
      ~target:"prod/gcp/us-central1"
      {|
target:
  destroy_retention: none
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_str_opt
        "destroy_retention reaches the resolved target"
        (Some "none")
        target.Sol_cli_config.destroy_retention)
;;

(* GCP, first live attempt (2026-09-19): `create_rds`, `rds_multi_az`,
   `ecr_repositories` and `workspace_name` were routed to *every* target's root,
   and the GCP cloud root declares none of them -- so the first live GCP command
   died with four "Value for undeclared variable" errors before terraform could
   plan anything. A variable a root does not declare is an error, not a no-op, so
   which root declares what is part of the mapping. *)
(* Attempt 2: creating the provisioner identity does not let anyone use it. Sol
   reaches the cluster by impersonating it, so the root has to grant the *declared*
   caller roles/iam.serviceAccountTokenCreator on that one identity -- and a target
   that names no caller must produce no grant, rather than defaulting to whoever ran
   Sol. Inferring the caller is the ambient-authority escape hatch the field exists
   to close, so "absent" and "named" have to differ observably. *)
let test_provisioner_impersonator_reaches_the_gcp_root () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  gcp:
    project_id: sol-qualification
    provisioner_impersonator: user:ops@example.test
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_str_opt
           "the declared caller reaches the GCP root as the list the root declares"
           (Some {|["user:ops@example.test"]|})
           (List.assoc_opt "provisioner_impersonators" vars)))
;;

let test_absent_provisioner_impersonator_grants_nobody () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  gcp:
    project_id: sol-qualification
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_bool
           "no caller named means no impersonation, not the caller's own identity"
           false
           (List.mem_assoc "provisioner_impersonators" vars)))
;;

(* REFAC-098: provider-native identity lives in the provider's own block. A flat
   key is refused with the place it moved to, never silently ignored -- a dropped
   lock table would be a concurrent-apply hazard. *)
let test_flat_provider_key_is_refused () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Alcotest.fail "a flat provider-native key must be refused"
    | Error e ->
      let message = Sol_cli_config.error_to_string e in
      check_bool
        "names where the key now lives"
        true
        (Sol_cli_string.contains ~needle:"aws.provisioner_role_arn" message))
;;

(* A workspace declares both providers' identity in one shared file; each target
   reads only its own provider's block, so a GCP target cannot carry AWS role ARNs.
   The AWS target is the positive control: the same file does give it the role. *)
let test_gcp_target_cannot_carry_aws_identity () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    state_lock_table: acme-tflock
  gcp:
    project_id: sol-qualification
|};
    let target_of name =
      match Sol_cli_config.load_for_target ~target:name with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg -> cfg, cfg.Sol_cli_config.target
    in
    let gcp_cfg, gcp = target_of "prod/gcp/us-central1" in
    let _, aws = target_of "prod/aws/us-east-1" in
    check_str_opt
      "the GCP target reads no AWS role"
      None
      (Sol_cli_config.provider_field gcp "provisioner_role_arn");
    check_str_opt
      "the AWS target does (positive control)"
      (Some "arn:aws:iam::111122223333:role/sol-provisioner")
      (Sol_cli_config.provider_field aws "provisioner_role_arn");
    match Sol_cli_terraform_vars.of_config ~workspace:"pluto" gcp_cfg with
    | Error msg -> Alcotest.fail msg
    | Ok vars ->
      check_bool
        "no AWS key reaches the GCP root"
        false
        (List.mem_assoc "provisioner_role_arn" vars
         || List.mem_assoc "state_lock_table" vars))
;;

(* The keys Sol consumes from a provider block are not Terraform variables: the
   lock table is backend configuration, and passing it as a `-var` would fail the
   command on an undeclared variable. The role it routes is still there. *)
let test_sol_owned_keys_are_not_passed_through () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    state_lock_table: acme-tflock
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    some_root_variable: passed
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_bool
           "the lock table is not a -var"
           false
           (List.mem_assoc "state_lock_table" vars);
         Alcotest.(check int)
           "the provisioner role is routed exactly once"
           1
           (List.length (List.filter (fun (k, _) -> k = "provisioner_role_arn") vars));
         check_str_opt
           "an ordinary provider-block variable still passes through"
           (Some "passed")
           (List.assoc_opt "some_root_variable" vars)))
;;

let test_provisioner_impersonator_survives_the_merge () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  base_domain: example.test
|};
    mkdir_p "sol/prod/gcp";
    Targets_fixture.write
      ~target:"prod/gcp/us-central1"
      {|
target:
  gcp:
    provisioner_impersonator: user:ops@example.test
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      check_str_opt
        "the declared caller survives the merge"
        (Some "user:ops@example.test")
        (Sol_cli_config.provider_field target "provisioner_impersonator"))
;;

(* INFRA-074: the ECR repository list is derived from the workloads with a
   Dockerfile. A workspace with no [app/] yet has no repositories; a workload
   without a Dockerfile has none either (and the cloud-apply plan guard is what
   stops that from silently deleting an existing one). *)
let ecr_repositories_of_workspace () =
  write "sol.yml" "target:\n  aws:\n    vpc_cidr: \"10.42.0.0/16\"\n";
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
  | Ok cfg ->
    (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
     | Error msg -> Alcotest.fail msg
     | Ok vars -> List.assoc_opt "ecr_repositories" vars)
;;

let test_ecr_repositories_without_app_dir_are_empty () =
  with_temp_dir (fun () ->
    check_str_opt
      "no app/ -> no repositories"
      (Some "[]")
      (ecr_repositories_of_workspace ()))
;;

let test_ecr_repositories_follow_dockerfiles () =
  with_temp_dir (fun () ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    mkdir_p "app/payments/refund_svc";
    check_str_opt
      "only the workload with a Dockerfile"
      (Some {|["charge-svc"]|})
      (ecr_repositories_of_workspace ()))
;;

(* INFRA-077 / FND-0057: a `destroy_retention: none` GCP target creates its
   observability buckets with soft delete off, so its destroy leaves nothing billed;
   any other target declares GCS's 7 days explicitly; the AWS root never sees it. *)
let test_gcs_soft_delete_follows_destroy_retention () =
  let soft_delete ~target ~retention =
    with_temp_dir (fun () ->
      write "sol.yml" "target:\n  base_domain: example.test\n";
      (match retention with
       | None -> ()
       | Some r ->
         Targets_fixture.write ~target ("target:\n  destroy_retention: " ^ r ^ "\n"));
      match Sol_cli_config.load_for_target ~target with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg ->
        (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
         | Error msg -> Alcotest.fail msg
         | Ok vars -> List.assoc_opt "gcs_soft_delete_retention_seconds" vars))
  in
  check_str_opt
    "GCP none: soft delete off"
    (Some "0")
    (soft_delete ~target:"prod/gcp/us-central1" ~retention:(Some "none"));
  check_str_opt
    "GCP default: 7 days, explicit"
    (Some "604800")
    (soft_delete ~target:"prod/gcp/us-central1" ~retention:None);
  check_str_opt
    "GCP final-snapshot: 7 days, explicit"
    (Some "604800")
    (soft_delete ~target:"prod/gcp/us-central1" ~retention:(Some "final-snapshot"));
  check_str_opt
    "the AWS root does not declare it"
    None
    (soft_delete ~target:"prod/aws/us-east-1" ~retention:(Some "none"))
;;

let test_terraform_vars_are_provider_shaped () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  gcp:
    project_id: sol-qualification
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_bool
           "the GCP root's own variable reaches it"
           true
           (List.mem ("project_id", "sol-qualification") vars);
         check_bool "region reaches it" true (List.mem ("region", "us-central1") vars);
         List.iter
           (fun aws_only ->
              check_bool
                (Printf.sprintf "%s must not reach the GCP root" aws_only)
                false
                (List.mem_assoc aws_only vars))
           [ "create_rds"
           ; "rds_multi_az"
           ; "ecr_repositories"
           ; "workspace_name"
           ; "provisioner_role_arn"
           ; "cluster_endpoint_cidr"
           ; "deploy_role_arn"
           ]))
;;

let test_terraform_vars_workspace_name_and_ecr_repositories () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
|};
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    mkdir_p "app/comms/notify_worker";
    write "app/comms/notify_worker/Dockerfile" "FROM scratch\n";
    (* No Dockerfile here -- discover_services skips it, so it must not
       appear in ecr_repositories either. *)
    mkdir_p "app/comms/spike_fn";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_str_opt
           "workspace_name"
           (Some "pluto")
           (List.assoc_opt "workspace_name" vars);
         (match List.assoc_opt "ecr_repositories" vars with
          | None -> Alcotest.fail "expected ecr_repositories var"
          | Some ecr ->
            check_bool
              "charge-svc present"
              true
              (Sol_cli_string.contains ~needle:"\"charge-svc\"" ecr);
            check_bool
              "notify-worker present"
              true
              (Sol_cli_string.contains ~needle:"\"notify-worker\"" ecr);
            check_bool
              "spike-fn absent (no Dockerfile)"
              false
              (Sol_cli_string.contains ~needle:"spike-fn" ecr))))
;;

let test_production_profile_enables_rds_multi_az () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      "target:\n  profile: production-single-region\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_str_opt "RDS Multi-AZ" (Some "true") (List.assoc_opt "rds_multi_az" vars)))
;;

(* Reviewer-prompted (2026-09-18): rds_multi_az's Terraform default is
   already false, so stating it explicitly changes nothing for a
   non-production target. rds_deletion_protection's default is true, so the
   analogous mistake -- forcing a value for every target rather than only
   the one that must not be weakened -- would have silently disabled
   protection for every target without a production profile. This asserts
   the asymmetry directly: the key is present, forced true, only for a
   production target using Postgres. *)
let test_production_profile_enables_rds_deletion_protection () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      "target:\n  profile: production-single-region\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_str_opt
           "RDS deletion protection"
           (Some "true")
           (List.assoc_opt "rds_deletion_protection" vars)))
;;

let test_non_production_target_leaves_rds_deletion_protection_unset () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      "target:\n  cluster_name: dev-cluster\n";
    match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         (* Absent, not "false": a target with no profile must keep relying
            on the Terraform variable's own protective default, exactly as
            it did before this variable was ever named here. Emitting
            "false" would be the regression the asymmetry above guards
            against. *)
         check_str_opt
           "no forced value without a production profile"
           None
           (List.assoc_opt "rds_deletion_protection" vars)))
;;

(* The invariant a --var/var-file override cannot be allowed to defeat: for a
   production-profile target, Terraform resolves a repeated -var by taking
   the *last* occurrence, so vars_with_profile_precedence's ordering is the
   entire enforcement mechanism, independent of any one variable's value.
   Simulates Terraform's own resolution rather than only asserting order,
   so a change that reordered but still "looked right" would still be
   caught if it stopped actually working. *)
let effective_value key vars =
  List.fold_left
    (fun acc v ->
       match String.index_opt v '=' with
       | Some i when String.sub v 0 i = key ->
         Some (String.sub v (i + 1) (String.length v - i - 1))
       | _ -> acc)
    None
    vars
;;

let test_profile_precedence_defeats_a_conflicting_override () =
  let cli_vars = [ "rds_deletion_protection=false" ] in
  let config_vars = [ "rds_deletion_protection=true" ] in
  check_str_opt
    "production profile: override defeated, profile value wins"
    (Some "true")
    (effective_value
       "rds_deletion_protection"
       (Sol_cli_config.vars_with_profile_precedence
          ~has_profile:true
          ~cli_vars
          ~config_vars));
  check_str_opt
    "no profile: ordinary target keeps full operator control"
    (Some "false")
    (effective_value
       "rds_deletion_protection"
       (Sol_cli_config.vars_with_profile_precedence
          ~has_profile:false
          ~cli_vars
          ~config_vars))
;;

(* HARDEN-002 (run 1): cluster_issuer is a platform/cloud/modules/platform variable. It
   used to be sent to the provider root too, and terraform aborts the whole
   command when a variable is assigned that the root does not declare:
   "A variable named \"cluster_issuer\" was assigned on the command line, but the
   root module does not declare a variable of that name." A documented target
   using it must still provision through sol cloud apply. *)
let test_terraform_vars_route_cluster_issuer_to_the_base_layer () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  cluster_issuer: letsencrypt-staging
  cluster_endpoint_cidr: 203.0.113.0/24
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_bool
           "cluster_issuer is not routed to the provider root"
           false
           (List.mem_assoc "cluster_issuer" vars);
         check_str_opt
           "a provider-root variable the root does declare is still routed"
           (Some "203.0.113.0/24")
           (List.assoc_opt "cluster_endpoint_cidr" vars)))
;;

(* HARDEN-002 run 3, finding 11: the AWS provider root declares
   `deploy_role_arn` and uses it to create the deploy identity's EKS access
   entry (INFRA-025), but Sol_cli_terraform_vars.of_config never routed the
   target's value there -- so the entry was never created and the module's
   deploy_kubeconfig_command/deploy_kube_context outputs stayed null.

   DEC-038 changed the other half of this: the AWS root now *does* declare
   operator_role_arn (the operator's read-only EKS access entry), so it is routed
   too. It used to be excluded precisely because the root did not declare it --
   which was the reason the operator identity Sol documents could not exist. Same
   bug class, so the same assertion. *)
let test_terraform_vars_route_deploy_role_arn () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
    deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
    operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
  cluster_endpoint_cidr: 203.0.113.0/24
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_str_opt
           "deploy_role_arn is routed to the provider root"
           (Some "arn:aws:iam::111122223333:role/sol-deploy")
           (List.assoc_opt "deploy_role_arn" vars);
         check_str_opt
           "provisioner_role_arn is routed"
           (Some "arn:aws:iam::111122223333:role/sol-provisioner")
           (List.assoc_opt "provisioner_role_arn" vars);
         check_str_opt
           "cluster_access_role_arn is routed"
           (Some "arn:aws:iam::111122223333:role/sol-cluster-access")
           (List.assoc_opt "cluster_access_role_arn" vars);
         check_str_opt
           "operator_role_arn is routed to the provider root (DEC-038)"
           (Some "arn:aws:iam::111122223333:role/sol-operator")
           (List.assoc_opt "operator_role_arn" vars)))
;;

let test_terraform_vars_ecr_repositories_empty_without_app_dir () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Alcotest.fail msg
       | Ok vars ->
         check_str_opt
           "ecr_repositories"
           (Some "[]")
           (List.assoc_opt "ecr_repositories" vars)))
;;

let test_example_pluto_prod_target_parses () =
  with_chdir (example_pluto_dir ()) (fun () ->
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let resource =
        Sol_cli_config.resources cfg
        |> List.find (fun (r : Sol_cli_config.resource) -> r.name = "app_db")
      in
      check_str_opt "size" (Some "small") resource.size)
;;

(* `local` is not an environment: it names Sol's own ephemeral substrate, and
   reserving the word keeps it from also meaning a selectable one. A cluster
   someone runs themselves is still a cluster, and gets named for itself
   (DEC-016, REFAC-083). *)
let test_local_env_is_reserved () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"local/aws/us-east-1" with
    | Ok _ -> Alcotest.fail "expected `local` to be rejected as an env name"
    | Error e ->
      assert (Sol_cli_string.contains ~needle:"reserved" e.message);
      assert (Sol_cli_string.contains ~needle:"sol local infra up" e.message))
;;

(* REFAC-086: the name `local` is reserved, and so is the cluster behind it. A
   target pointed at the local substrate would hand target semantics to Sol's
   ephemeral cluster — the synthetic local target the reservation exists to
   prevent, arriving through the back door. *)
let test_target_cannot_resolve_to_the_local_destination () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  kube_context: k3d-sol-local
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.Sol_cli_config.target in
      (match Sol_cli_config.destination_of_target target with
       | Ok _ -> Alcotest.fail "a configured target must not resolve to the local cluster"
       | Error message ->
         assert (String.length message > 0);
         assert (String.length message > 0 && message <> "")))
;;

(* REFAC-106: what a real YAML parser adds. *)
let test_yaml_flow_map_and_exact_text () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol";
    write
      "sol/environments.yml"
      {|prod: { targets: { aws/us-east-1: { registry: r.example.com, cluster_name: 012,
  base_domain: "1.10", services: { api: { scale: { min: 1, max: 3 } } } } } }
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let t = cfg.Sol_cli_config.target in
      check_str "registry" "r.example.com" (Option.value t.registry ~default:"");
      (* numeric-looking text stays the text the user wrote *)
      check_str "cluster_name" "012" (Option.value t.cluster_name ~default:"");
      check_str "base_domain" "1.10" (Option.value t.base_domain ~default:""))
;;

let test_yaml_duplicate_key_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    type: http
  api:
    type: worker
|};
    expect_load_error "duplicate service \"api\"")
;;

let test_yaml_syntax_error_names_its_line () =
  with_temp_dir (fun () ->
    write "sol.yml" "project: p\nservices:\n  api:\n    uses: [app_db\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Alcotest.fail "expected a YAML syntax error"
    | Error e -> Alcotest.(check int) "line" 4 e.line)
;;

(* BUG-057: the flag is relative to the shell, a target's var file to the workspace
   root; the flag wins; absolute paths pass through. *)
let test_var_file_resolution () =
  let resolve =
    Sol_cli_terraform_vars.var_file ~cwd:"/ws/app/deep" ~workspace_root:"/ws"
  in
  let check name want got = Alcotest.(check (option string)) name want got in
  check
    "a target's relative path is from the workspace root"
    (Some "/ws/vars/x.tfvars")
    (resolve ~flag:None ~target:(Some "vars/x.tfvars"));
  check
    "a relative flag is from the shell's directory"
    (Some "/ws/app/deep/f.tfvars")
    (resolve ~flag:(Some "f.tfvars") ~target:None);
  check
    "the flag wins over the target"
    (Some "/ws/app/deep/f.tfvars")
    (resolve ~flag:(Some "f.tfvars") ~target:(Some "vars/x.tfvars"));
  check
    "an absolute target path is used as written"
    (Some "/abs/x.tfvars")
    (resolve ~flag:None ~target:(Some "/abs/x.tfvars"));
  check "no var file" None (resolve ~flag:None ~target:None)
;;

(* FEAT-100 / DEC-047: sol.yml -> environment -> target, and the local file. *)
let write_envs ?local text =
  mkdir_p "sol";
  write "sol/environments.yml" text;
  Option.iter (write "sol/environments.local.yml") local
;;

let resolve_ok target =
  match Sol_cli_config.load_for_target ~target with
  | Ok cfg -> cfg
  | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
;;

let resolve_error target =
  match Sol_cli_config.load_for_target ~target with
  | Ok _ -> Alcotest.fail ("expected " ^ target ^ " to be refused")
  | Error e -> e.message
;;

let target_of (cfg : Sol_cli_config.t) = cfg.target

let service cfg name =
  List.find
    (fun (s : Sol_cli_config.service) -> s.name = name)
    (Sol_cli_config.services cfg)
;;

let check_contains name ~needle haystack =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack && (String.sub haystack i n = needle || go (i + 1))
  in
  Alcotest.(check bool) (name ^ ": " ^ haystack) true (go 0)
;;

let test_env_layer_precedence () =
  with_temp_dir (fun () ->
    write "sol.yml" "project: p\ntarget:\n  base_domain: from-sol-yml.test\n";
    write_envs
      {|prod:
  base_domain: from-env.test
  letsencrypt_email: ops@env.test
  targets:
    aws/us-east-1:
      letsencrypt_email: ops@target.test
      cluster_name: east
    aws/us-west-2:
      cluster_name: west
|};
    let east = target_of (resolve_ok "prod/aws/us-east-1") in
    let west = target_of (resolve_ok "prod/aws/us-west-2") in
    check_str "env overrides sol.yml" "from-env.test" (Option.get east.base_domain);
    check_str "target overrides env" "ops@target.test" (Option.get east.letsencrypt_email);
    check_str "env inherited" "ops@env.test" (Option.get west.letsencrypt_email);
    check_str "target-only key" "west" (Option.get west.cluster_name))
;;

let test_scale_and_provider_blocks_deep_merge () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      {|prod:
  aws:
    state_lock_table: lock
  services:
    api:
      scale:
        min: 2
  targets:
    aws/us-east-1:
      aws:
        provisioner_role_arn: arn:aws:iam::1:role/p
      services:
        api:
          scale:
            max: 5
|};
    let cfg = resolve_ok "prod/aws/us-east-1" in
    let api = service cfg "api" in
    Alcotest.(check (option int)) "env min survives" (Some 2) api.scale_min;
    Alcotest.(check (option int)) "target max" (Some 5) api.scale_max;
    let t = target_of cfg in
    Alcotest.(check (option string))
      "env provider field survives"
      (Some "lock")
      (Sol_cli_config.provider_field t "state_lock_table");
    Alcotest.(check (option string))
      "target provider field"
      (Some "arn:aws:iam::1:role/p")
      (Sol_cli_config.provider_field t "provisioner_role_arn"))
;;

let test_omit_is_sticky () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      {|dev:
  services:
    api:
      omit: true
  targets:
    aws/us-east-1:
      services:
        api:
          omit: false
|};
    let cfg = resolve_ok "dev/aws/us-east-1" in
    Alcotest.(check bool)
      "a target cannot bring back what its environment omitted"
      false
      (List.exists
         (fun (s : Sol_cli_config.service) -> s.name = "api")
         (Sol_cli_config.services cfg)))
;;

let test_target_only_key_rejected_at_env_level () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs "prod:\n  cluster_name: shared\n  targets:\n    aws/us-east-1:\n";
    check_contains
      "message"
      ~needle:"cluster_name is target-only"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_app_shape_rejected_outside_sol_yml () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      "prod:\n\
      \  targets:\n\
      \    aws/us-east-1:\n\
      \      services:\n\
      \        api:\n\
      \          path: elsewhere\n";
    check_contains
      "message"
      ~needle:"services.api.path belongs in sol.yml"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_undeclared_service_rejected () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      "prod:\n  services:\n    ghost:\n      omit: true\n  targets:\n    aws/us-east-1:\n";
    check_contains
      "message"
      ~needle:"service \"ghost\" is not declared in sol.yml"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_local_file_adds_keys_and_environments () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      ~local:
        {|prod:
  targets:
    aws/us-east-1:
      registry: 123456789012.dkr.ecr.us-east-1.amazonaws.com
qual:
  targets:
    gcp/us-central1:
      cluster_name: sol-qual
|}
      "prod:\n  targets:\n    aws/us-east-1:\n      cluster_name: prod\n";
    let prod = target_of (resolve_ok "prod/aws/us-east-1") in
    check_str "tracked key" "prod" (Option.get prod.cluster_name);
    check_str
      "local key"
      "123456789012.dkr.ecr.us-east-1.amazonaws.com"
      (Option.get prod.registry);
    let qual = target_of (resolve_ok "qual/gcp/us-central1") in
    check_str "local-only environment" "sol-qual" (Option.get qual.cluster_name))
;;

let test_local_file_may_not_change_tracked_keys () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      ~local:"prod:\n  targets:\n    aws/us-east-1:\n      cluster_name: other\n"
      "prod:\n  targets:\n    aws/us-east-1:\n      cluster_name: prod\n";
    check_contains
      "message"
      ~needle:"cluster_name is already set in sol/environments.yml"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_per_target_files_refused () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    write "sol/prod/aws/us-east-1.yml" "target:\n  cluster_name: old\n";
    check_contains
      "message"
      ~needle:"per-target files are no longer read"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_project_rejected_in_environment () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs "prod:\n  project: nope\n  targets:\n    aws/us-east-1:\n";
    check_contains
      "message"
      ~needle:"project belongs in sol.yml"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_declared_targets_are_discovered () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      ~local:"qual:\n  targets:\n    gcp/us-central1:\n"
      "prod:\n  targets:\n    aws/us-east-1:\n    aws/us-west-2:\n";
    match Sol_cli_config.discover_target_paths () with
    | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
    | Ok paths ->
      Alcotest.(check (list string))
        "targets"
        [ "prod/aws/us-east-1"; "prod/aws/us-west-2"; "qual/gcp/us-central1" ]
        paths)
;;

let () =
  Alcotest.run
    "config"
    [ ( "sol.yml"
      , [ Alcotest.test_case "local env is reserved" `Quick test_local_env_is_reserved
        ; Alcotest.test_case
            "target path supplies placement"
            `Quick
            test_target_path_supplies_placement
        ; Alcotest.test_case
            "target overlay omits entries"
            `Quick
            test_target_overlay_can_omit_resources_and_services
        ; Alcotest.test_case
            "observability_backend parsed"
            `Quick
            test_target_observability_backend_parsed
        ; Alcotest.test_case
            "observability_backend absent when unset"
            `Quick
            test_target_observability_backend_absent_when_unset
        ; Alcotest.test_case
            "alert delivery declaration parsed"
            `Quick
            test_target_alert_delivery_parsed
        ; Alcotest.test_case
            "recoverable state and identities parsed"
            `Quick
            test_target_recoverable_state_and_identities_parsed
        ; Alcotest.test_case "bad target path fails" `Quick test_bad_target_path_fails
        ; Alcotest.test_case
            "unknown target provider fails"
            `Quick
            test_unknown_target_provider_fails
        ; Alcotest.test_case
            "parent target path fails"
            `Quick
            test_parent_target_path_fails
        ; Alcotest.test_case
            "target outside a workspace fails closed"
            `Quick
            test_target_outside_a_workspace_fails_closed
        ; Alcotest.test_case
            "target with only sol.yml succeeds"
            `Quick
            test_target_with_only_sol_yml_succeeds
        ; Alcotest.test_case
            "same cluster across envs fails"
            `Quick
            test_same_cluster_across_envs_fails
        ; Alcotest.test_case
            "different destinations succeed"
            `Quick
            test_different_destinations_succeed
        ; Alcotest.test_case
            "destination comes from the target"
            `Quick
            test_destination_comes_from_the_target
        ; Alcotest.test_case
            "destination includes scoped kubeconfig"
            `Quick
            test_destination_includes_scoped_kubeconfig
        ; Alcotest.test_case
            "missing destination fails closed"
            `Quick
            test_destination_missing_fails_closed
        ; Alcotest.test_case
            "a target cannot resolve to the local destination"
            `Quick
            test_target_cannot_resolve_to_the_local_destination
        ; Alcotest.test_case
            "duplicate resource fails"
            `Quick
            test_duplicate_resource_fails
        ; Alcotest.test_case "unknown key fails" `Quick test_unknown_key_fails
        ; Alcotest.test_case "service language parses" `Quick test_service_language_parses
        ; Alcotest.test_case
            "unknown service language fails"
            `Quick
            test_unknown_service_language_fails
        ; Alcotest.test_case
            "duplicate top-level section fails"
            `Quick
            test_duplicate_top_level_section_fails
        ; Alcotest.test_case "duplicate index fails" `Quick test_duplicate_index_fails
        ; Alcotest.test_case "malformed list fails" `Quick test_malformed_list_fails
        ; Alcotest.test_case
            "malformed quoted scalar fails"
            `Quick
            test_malformed_quoted_scalar_fails
        ; Alcotest.test_case
            "malformed quoted list item fails"
            `Quick
            test_malformed_quoted_list_item_fails
        ; Alcotest.test_case
            "undeclared uses ref fails"
            `Quick
            test_undeclared_uses_ref_fails
        ; Alcotest.test_case
            "absolute cross-region uses ref parses"
            `Quick
            test_absolute_cross_region_uses_ref_parses
        ; Alcotest.test_case
            "cross-provider uses ref fails"
            `Quick
            test_cross_provider_uses_ref_fails
        ; Alcotest.test_case
            "cross-env uses ref fails"
            `Quick
            test_cross_env_uses_ref_fails
        ; Alcotest.test_case
            "three-segment cross-env uses ref fails"
            `Quick
            test_three_segment_cross_env_uses_ref_fails
        ; Alcotest.test_case
            "two-segment cross-provider uses ref fails"
            `Quick
            test_two_segment_cross_provider_uses_ref_fails
        ; Alcotest.test_case
            "empty-segment uses ref fails to parse"
            `Quick
            test_empty_segment_uses_ref_fails_to_parse
        ; Alcotest.test_case
            "omitted resource uses ref fails"
            `Quick
            test_omitted_resource_uses_ref_fails
        ; Alcotest.test_case
            "resource key after indexes parses"
            `Quick
            test_resource_key_after_indexes_parses
        ; Alcotest.test_case
            "service key after scale parses"
            `Quick
            test_service_key_after_scale_parses
        ; Alcotest.test_case
            "nested provider box tolerated"
            `Quick
            test_nested_provider_box_still_tolerated
        ; Alcotest.test_case
            "provider box ends before generic key"
            `Quick
            test_target_provider_box_ends_before_generic_key
        ; Alcotest.test_case
            "empty target value fails"
            `Quick
            test_empty_target_value_fails
        ; Alcotest.test_case
            "target after resources parses"
            `Quick
            test_target_after_resources_parses
        ; Alcotest.test_case "quoted hash survives" `Quick test_quoted_hash_survives
        ; Alcotest.test_case
            "single quoted hash survives"
            `Quick
            test_single_quoted_hash_survives
        ; Alcotest.test_case "malformed int fails" `Quick test_malformed_int_fails
        ; Alcotest.test_case "malformed bool fails" `Quick test_malformed_bool_fails
        ; Alcotest.test_case
            "root target defaults survive"
            `Quick
            test_root_target_defaults_survive
        ; Alcotest.test_case
            "FEAT-028 shapes tolerated"
            `Quick
            test_feat_028_shapes_still_tolerated
        ; Alcotest.test_case
            "provider box round trips"
            `Quick
            test_provider_box_round_trips
        ; Alcotest.test_case
            "duplicate provider box fails"
            `Quick
            test_duplicate_provider_box_fails
        ; Alcotest.test_case
            "unknown provider box fails"
            `Quick
            test_unknown_provider_box_fails
        ; Alcotest.test_case
            "provider fields feed terraform vars"
            `Quick
            test_provider_fields_feed_active_terraform_provider
        ; Alcotest.test_case
            "ECR repositories: no app/ is empty (INFRA-074)"
            `Quick
            test_ecr_repositories_without_app_dir_are_empty
        ; Alcotest.test_case
            "ECR repositories follow Dockerfiles (INFRA-074)"
            `Quick
            test_ecr_repositories_follow_dockerfiles
        ; Alcotest.test_case
            "destroy_retention survives the merge"
            `Quick
            test_destroy_retention_survives_the_merge
        ; Alcotest.test_case
            "provisioner impersonator: reaches the GCP root"
            `Quick
            test_provisioner_impersonator_reaches_the_gcp_root
        ; Alcotest.test_case
            "provisioner impersonator: absent grants nobody"
            `Quick
            test_absent_provisioner_impersonator_grants_nobody
        ; Alcotest.test_case
            "provisioner impersonator: survives the merge"
            `Quick
            test_provisioner_impersonator_survives_the_merge
        ; Alcotest.test_case
            "REFAC-098: a flat provider-native key is refused"
            `Quick
            test_flat_provider_key_is_refused
        ; Alcotest.test_case
            "REFAC-098: a GCP target cannot carry AWS identity"
            `Quick
            test_gcp_target_cannot_carry_aws_identity
        ; Alcotest.test_case
            "REFAC-098: Sol-owned keys are not passed through"
            `Quick
            test_sol_owned_keys_are_not_passed_through
        ; Alcotest.test_case
            "terraform vars: provider-shaped"
            `Quick
            test_terraform_vars_are_provider_shaped
        ; Alcotest.test_case
            "terraform vars: GCS soft delete follows destroy_retention"
            `Quick
            test_gcs_soft_delete_follows_destroy_retention
        ; Alcotest.test_case
            "terraform vars: workspace_name + ecr_repositories"
            `Quick
            test_terraform_vars_workspace_name_and_ecr_repositories
        ; Alcotest.test_case
            "production profile enables RDS Multi-AZ"
            `Quick
            test_production_profile_enables_rds_multi_az
        ; Alcotest.test_case
            "production profile enables RDS deletion protection"
            `Quick
            test_production_profile_enables_rds_deletion_protection
        ; Alcotest.test_case
            "non-production target leaves RDS deletion protection unset"
            `Quick
            test_non_production_target_leaves_rds_deletion_protection_unset
        ; Alcotest.test_case
            "profile precedence defeats a conflicting override"
            `Quick
            test_profile_precedence_defeats_a_conflicting_override
        ; Alcotest.test_case
            "terraform vars: cluster_issuer stays in the base layer"
            `Quick
            test_terraform_vars_route_cluster_issuer_to_the_base_layer
        ; Alcotest.test_case
            "terraform vars: deploy_role_arn reaches the provider root"
            `Quick
            test_terraform_vars_route_deploy_role_arn
        ; Alcotest.test_case
            "terraform vars: ecr_repositories empty without app/"
            `Quick
            test_terraform_vars_ecr_repositories_empty_without_app_dir
        ; Alcotest.test_case
            "example pluto prod target parses"
            `Quick
            test_example_pluto_prod_target_parses
        ; Alcotest.test_case
            "environments: layer precedence"
            `Quick
            test_env_layer_precedence
        ; Alcotest.test_case
            "environments: scale and provider blocks deep-merge"
            `Quick
            test_scale_and_provider_blocks_deep_merge
        ; Alcotest.test_case "environments: omit is sticky" `Quick test_omit_is_sticky
        ; Alcotest.test_case
            "environments: target-only key rejected at env level"
            `Quick
            test_target_only_key_rejected_at_env_level
        ; Alcotest.test_case
            "environments: app shape rejected outside sol.yml"
            `Quick
            test_app_shape_rejected_outside_sol_yml
        ; Alcotest.test_case
            "environments: undeclared service rejected"
            `Quick
            test_undeclared_service_rejected
        ; Alcotest.test_case
            "environments: local file adds keys and environments"
            `Quick
            test_local_file_adds_keys_and_environments
        ; Alcotest.test_case
            "environments: local file may not change tracked keys"
            `Quick
            test_local_file_may_not_change_tracked_keys
        ; Alcotest.test_case
            "environments: per-target files refused"
            `Quick
            test_per_target_files_refused
        ; Alcotest.test_case
            "environments: project rejected in an environment"
            `Quick
            test_project_rejected_in_environment
        ; Alcotest.test_case
            "environments: declared targets are discovered"
            `Quick
            test_declared_targets_are_discovered
        ; Alcotest.test_case
            "yaml: flow maps and exact scalar text (REFAC-106)"
            `Quick
            test_yaml_flow_map_and_exact_text
        ; Alcotest.test_case
            "yaml: duplicate key fails"
            `Quick
            test_yaml_duplicate_key_fails
        ; Alcotest.test_case
            "yaml: syntax error names its line"
            `Quick
            test_yaml_syntax_error_names_its_line
        ; Alcotest.test_case
            "terraform vars: var file resolution (BUG-057)"
            `Quick
            test_var_file_resolution
        ] )
    ]
;;
