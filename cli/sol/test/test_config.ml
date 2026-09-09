let check_str = Alcotest.(check string)
let check_strs = Alcotest.(check (list string))
let check_int_opt = Alcotest.(check (option int))
let check_bool = Alcotest.(check bool)
let check_str_opt = Alcotest.(check (option string))

let check_provider label expected provider =
  check_str label expected (Sol_cli_provider.to_string provider)

let contains ~needle s =
  let nlen = String.length needle and slen = String.length s in
  let rec loop i =
    i + nlen <= slen && (String.sub s i nlen = needle || loop (i + 1))
  in
  nlen = 0 || loop 0

let only_index indexes =
  match indexes with
  | [ index ] -> index
  | _ -> Alcotest.fail "expected one index"

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let mkdir_p path =
  let parts = String.split_on_char '/' path in
  let rec loop current = function
    | [] -> ()
    | part :: rest ->
        let next =
          if current = "" then part else Filename.concat current part
        in
        (try Unix.mkdir next 0o755
         with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        loop next rest
  in
  loop "" parts

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

let with_chdir dir f =
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
      Sys.chdir dir;
      f ())

let expect_load_error expected =
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Ok _ -> Alcotest.fail "expected load_for_target to fail"
  | Error e -> check_str "message" expected e.message

let example_pluto_dir () =
  if Sys.file_exists "examples/pluto/sol.yml" then "examples/pluto"
  else "../../../../../examples/pluto"

let write_base () =
  write "sol.yml"
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

let test_target_path_supplies_placement () =
  with_temp_dir (fun () ->
      write_base ();
      mkdir_p "sol/prod/aws";
      write "sol/prod/aws/us-east-1.yml"
        {|
target:
  cluster_name: pluto-prod
  base_domain: pluto.example.com

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
          let target = Option.get (Sol_cli_config.target cfg) in
          check_str "target name" "prod/aws/us-east-1" target.name;
          check_str "env" "prod" target.env;
          check_provider "provider" "aws" target.provider;
          check_str "region" "us-east-1" target.region;
          check_str "cluster" "pluto-prod" (Option.get target.cluster_name);
          let resource = List.hd (Sol_cli_config.resources cfg) in
          check_str "resource" "app_db" resource.name;
          let service = List.hd (Sol_cli_config.services cfg) in
          check_str "service" "api" service.name;
          check_strs "uses" [ "app_db"; "sessions" ] service.uses;
          check_int_opt "scale min" (Some 2) service.scale_min;
          check_int_opt "scale max" (Some 10) service.scale_max)

let test_duplicate_resource_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
resources:
  app_db:
    type: postgres
  app_db:
    type: dynamodb
|};
      expect_load_error "duplicate resource \"app_db\"")

let test_unknown_key_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
services:
  api:
    typo: nope
|};
      expect_load_error "unknown service key \"typo\"")

let test_duplicate_top_level_section_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
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

let test_duplicate_index_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
resources:
  sessions:
    type: dynamodb
    indexes:
      by_expires_at:
      by_expires_at:
|};
      expect_load_error "duplicate index \"by_expires_at\"")

let test_malformed_list_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
services:
  api:
    uses: [app_db
|};
      expect_load_error "malformed list for uses")

let test_malformed_quoted_scalar_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
services:
  api:
    path: "app/core/api
|};
      expect_load_error "malformed quoted value for path")

let test_malformed_quoted_list_item_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
services:
  api:
    uses: ["app_db]
|};
      expect_load_error "malformed quoted value for uses")

let test_undeclared_uses_ref_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
services:
  api:
    uses: [missing]
|};
      expect_load_error "service \"api\" uses undeclared resource \"missing\"")

let test_absolute_cross_region_uses_ref_parses () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
services:
  api:
    uses: [/us-east-1/analytics_db]
|};
      match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg ->
          let service = List.hd (Sol_cli_config.services cfg) in
          check_strs "uses" [ "/us-east-1/analytics_db" ] service.uses;
          check_str "formatted use" "/us-east-1/analytics_db (cross-region)"
            (Sol_cli_config.format_use_ref (List.hd service.uses)))

let test_cross_provider_uses_ref_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
services:
  api:
    uses: [/gcp/us-central1/analytics_db]
|};
      expect_load_error "cross-provider uses refs are not supported in v1")

let test_cross_env_uses_ref_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
services:
  api:
    uses: [/prod/aws/us-east-1/analytics_db]
|};
      expect_load_error "cross-env uses refs are not supported in v1")

let test_three_segment_cross_env_uses_ref_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
services:
  api:
    uses: [/prod/us-east-1/analytics_db]
|};
      expect_load_error "cross-env uses refs are not supported in v1")

let test_two_segment_cross_provider_uses_ref_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
services:
  api:
    uses: [/gcp/analytics_db]
|};
      expect_load_error "cross-provider uses refs are not supported in v1")

let test_empty_segment_uses_ref_fails_to_parse () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
services:
  api:
    uses: [/us-east-1//analytics_db]
|};
      expect_load_error "absolute uses ref must look like /<region>/<resource>")

let test_omitted_resource_uses_ref_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
resources:
  app_db:
    type: postgres

services:
  api:
    uses: [app_db]
|};
      mkdir_p "sol/prod/aws";
      write "sol/prod/aws/us-east-1.yml"
        {|
resources:
  app_db:
    omit: true
|};
      expect_load_error "service \"api\" uses undeclared resource \"app_db\"")

let test_resource_key_after_indexes_parses () =
  with_temp_dir (fun () ->
      write "sol.yml"
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

let test_service_key_after_scale_parses () =
  with_temp_dir (fun () ->
      write "sol.yml"
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

let test_nested_provider_box_still_tolerated () =
  with_temp_dir (fun () ->
      write "sol.yml"
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
          let target = Option.get (Sol_cli_config.target cfg) in
          check_str_opt "registry" (Some "registry.example.com") target.registry)

let test_target_provider_box_ends_before_generic_key () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
target:
  aws:
    account_id: "123456789012"
  registry: registry.example.com
    typo: nope
|};
      expect_load_error "unsupported sol.yml syntax")

let test_empty_target_value_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
target:
  registry:
|};
      expect_load_error "missing value for registry")

let test_target_after_resources_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
resources:
  app_db:
    type: postgres

target:
  registry: registry.example.com
|};
      expect_load_error "target must appear before resources or services")

let test_quoted_hash_survives () =
  with_temp_dir (fun () ->
      write "sol.yml"
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

let test_single_quoted_hash_survives () =
  with_temp_dir (fun () ->
      write "sol.yml"
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

let test_malformed_int_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
services:
  api:
    scale:
      min: abc
|};
      expect_load_error "expected integer for min")

let test_malformed_bool_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
resources:
  app_db:
    omit: TRUE
|};
      expect_load_error "expected true or false for omit")

let test_target_overlay_can_omit_resources_and_services () =
  with_temp_dir (fun () ->
      write_base ();
      mkdir_p "sol/dev/aws";
      write "sol/dev/aws/us-east-1.yml"
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

let test_target_observability_backend_parsed () =
  with_temp_dir (fun () ->
      write_base ();
      mkdir_p "sol/prod/aws";
      write "sol/prod/aws/us-east-1.yml"
        {|
target:
  base_domain: pluto.example.com
  observability_backend: self_hosted_durable
|};
      match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg ->
          let target = Option.get (Sol_cli_config.target cfg) in
          check_str "observability_backend" "self_hosted_durable"
            (Option.get target.observability_backend))

let test_target_observability_backend_absent_when_unset () =
  with_temp_dir (fun () ->
      write_base ();
      mkdir_p "sol/dev/aws";
      write "sol/dev/aws/us-east-1.yml" {|
target:
  cluster_name: sol-dev
|};
      match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg ->
          let target = Option.get (Sol_cli_config.target cfg) in
          check_bool "observability_backend absent" true
            (target.observability_backend = None))

let test_bad_target_path_fails () =
  with_temp_dir (fun () ->
      write_base ();
      match Sol_cli_config.load_for_target ~target:"prod" with
      | Ok _ -> Alcotest.fail "expected invalid target path"
      | Error e ->
          check_str "message" "target must look like <env>/<provider>/<region>"
            e.message)

let test_unknown_target_provider_fails () =
  with_temp_dir (fun () ->
      write_base ();
      match Sol_cli_config.load_for_target ~target:"prod/azure/us-east-1" with
      | Ok _ -> Alcotest.fail "expected unknown target provider"
      | Error e ->
          check_str "message" "unsupported provider \"azure\"" e.message)

let test_parent_target_path_fails () =
  with_temp_dir (fun () ->
      write_base ();
      match Sol_cli_config.load_for_target ~target:"../../etc" with
      | Ok _ -> Alcotest.fail "expected invalid target path"
      | Error e ->
          check_str "message" "target path must not contain '..'" e.message)

(* FEAT-026 round 1: load_for_target requires at least one of sol.yml or
   the target file to exist -- a target that's neither declared in a
   sol.yml nor has its own overlay file is just a well-shaped path
   (e.g. a known-provider target like dev/aws/us-west-2), not a real
   target. *)
let test_target_with_neither_file_fails () =
  with_temp_dir (fun () ->
      (* deliberately no write_base (), no sol.yml, no target file *)
      match Sol_cli_config.load_for_target ~target:"dev/aws/us-west-2" with
      | Ok _ ->
          Alcotest.fail
            "expected target with no sol.yml and no target file to fail"
      | Error e ->
          check_bool "message names the target" true
            (let needle = "dev/aws/us-west-2" and s = e.message in
             let n = String.length needle and l = String.length s in
             let found = ref false in
             for i = 0 to l - n do
               if String.sub s i n = needle then found := true
             done;
             !found))

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

let test_root_target_defaults_survive () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
target:
  registry: registry.example.com

services:
  api:
    type: http
|};
      mkdir_p "sol/prod/aws";
      write "sol/prod/aws/us-east-1.yml"
        {|
target:
  cluster_name: pluto-prod
|};
      match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg ->
          let target = Option.get (Sol_cli_config.target cfg) in
          check_str_opt "registry" (Some "registry.example.com") target.registry)

let test_feat_028_shapes_still_tolerated () =
  with_temp_dir (fun () ->
      write "sol.yml"
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
          let target = Option.get (Sol_cli_config.target cfg) in
          check_str "env" "prod" target.env;
          let resource = List.hd (Sol_cli_config.resources cfg) in
          let index = only_index resource.indexes in
          check_str "index" "by_expires_at" index.index_name;
          check_str_opt "index partition_key" (Some "tenant_id")
            index.partition_key;
          check_str_opt "index sort_key" (Some "expires_at") index.sort_key)

let test_provider_box_round_trips () =
  with_temp_dir (fun () ->
      write "sol.yml"
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
          let target = Option.get (Sol_cli_config.target cfg) in
          check_strs "aws fields"
            [ "vpc_cidr=10.42.0.0/16" ]
            (List.assoc "aws" target.provider_fields
            |> List.map (fun (k, v) -> k ^ "=" ^ v));
          check_strs "gcp fields" [ "project_id=pluto-dev" ]
            (List.assoc "gcp" target.provider_fields
            |> List.map (fun (k, v) -> k ^ "=" ^ v)))

let test_duplicate_provider_box_fails () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
  aws:
    account_id: "123456789012"
|};
      expect_load_error "duplicate target provider box \"aws\"")

let test_unknown_provider_box_fails () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
target:
  azure:
    subscription_id: pluto-dev
|};
      expect_load_error "unsupported provider \"azure\"")

let test_provider_fields_feed_active_terraform_provider () =
  with_temp_dir (fun () ->
      write "sol.yml"
        {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
  gcp:
    project_id: pluto-dev
|};
      match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg -> (
          match Sol_cli_config.terraform_vars ~workspace:"pluto" cfg with
          | Error msg -> Alcotest.fail msg
          | Ok vars ->
              check_bool "aws var present" true
                (List.mem ("vpc_cidr", "10.42.0.0/16") vars);
              check_bool "gcp var absent" false
                (List.mem ("project_id", "pluto-dev") vars)))

let test_terraform_vars_workspace_name_and_ecr_repositories () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
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
      | Ok cfg -> (
          match Sol_cli_config.terraform_vars ~workspace:"pluto" cfg with
          | Error msg -> Alcotest.fail msg
          | Ok vars -> (
              check_str_opt "workspace_name" (Some "pluto")
                (List.assoc_opt "workspace_name" vars);
              match List.assoc_opt "ecr_repositories" vars with
              | None -> Alcotest.fail "expected ecr_repositories var"
              | Some ecr ->
                  check_bool "charge-svc present" true
                    (contains ~needle:"\"charge-svc\"" ecr);
                  check_bool "notify-worker present" true
                    (contains ~needle:"\"notify-worker\"" ecr);
                  check_bool "spike-fn absent (no Dockerfile)" false
                    (contains ~needle:"spike-fn" ecr))))

let test_terraform_vars_ecr_repositories_empty_without_app_dir () =
  with_temp_dir (fun () ->
      write "sol.yml" {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
|};
      match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg -> (
          match Sol_cli_config.terraform_vars ~workspace:"pluto" cfg with
          | Error msg -> Alcotest.fail msg
          | Ok vars ->
              check_str_opt "ecr_repositories" (Some "[]")
                (List.assoc_opt "ecr_repositories" vars)))

let test_example_pluto_prod_target_parses () =
  with_chdir (example_pluto_dir ()) (fun () ->
      match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
      | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
      | Ok cfg ->
          let resource =
            Sol_cli_config.resources cfg
            |> List.find (fun (r : Sol_cli_config.resource) ->
                r.name = "app_db")
          in
          check_str_opt "size" (Some "small") resource.size)

let () =
  Alcotest.run "config"
    [
      ( "sol.yml",
        [
          Alcotest.test_case "target path supplies placement" `Quick
            test_target_path_supplies_placement;
          Alcotest.test_case "target overlay omits entries" `Quick
            test_target_overlay_can_omit_resources_and_services;
          Alcotest.test_case "observability_backend parsed" `Quick
            test_target_observability_backend_parsed;
          Alcotest.test_case "observability_backend absent when unset" `Quick
            test_target_observability_backend_absent_when_unset;
          Alcotest.test_case "bad target path fails" `Quick
            test_bad_target_path_fails;
          Alcotest.test_case "unknown target provider fails" `Quick
            test_unknown_target_provider_fails;
          Alcotest.test_case "parent target path fails" `Quick
            test_parent_target_path_fails;
          Alcotest.test_case "target with neither sol.yml nor overlay fails"
            `Quick test_target_with_neither_file_fails;
          Alcotest.test_case "target with only sol.yml succeeds" `Quick
            test_target_with_only_sol_yml_succeeds;
          Alcotest.test_case "duplicate resource fails" `Quick
            test_duplicate_resource_fails;
          Alcotest.test_case "unknown key fails" `Quick test_unknown_key_fails;
          Alcotest.test_case "duplicate top-level section fails" `Quick
            test_duplicate_top_level_section_fails;
          Alcotest.test_case "duplicate index fails" `Quick
            test_duplicate_index_fails;
          Alcotest.test_case "malformed list fails" `Quick
            test_malformed_list_fails;
          Alcotest.test_case "malformed quoted scalar fails" `Quick
            test_malformed_quoted_scalar_fails;
          Alcotest.test_case "malformed quoted list item fails" `Quick
            test_malformed_quoted_list_item_fails;
          Alcotest.test_case "undeclared uses ref fails" `Quick
            test_undeclared_uses_ref_fails;
          Alcotest.test_case "absolute cross-region uses ref parses" `Quick
            test_absolute_cross_region_uses_ref_parses;
          Alcotest.test_case "cross-provider uses ref fails" `Quick
            test_cross_provider_uses_ref_fails;
          Alcotest.test_case "cross-env uses ref fails" `Quick
            test_cross_env_uses_ref_fails;
          Alcotest.test_case "three-segment cross-env uses ref fails" `Quick
            test_three_segment_cross_env_uses_ref_fails;
          Alcotest.test_case "two-segment cross-provider uses ref fails" `Quick
            test_two_segment_cross_provider_uses_ref_fails;
          Alcotest.test_case "empty-segment uses ref fails to parse" `Quick
            test_empty_segment_uses_ref_fails_to_parse;
          Alcotest.test_case "omitted resource uses ref fails" `Quick
            test_omitted_resource_uses_ref_fails;
          Alcotest.test_case "resource key after indexes parses" `Quick
            test_resource_key_after_indexes_parses;
          Alcotest.test_case "service key after scale parses" `Quick
            test_service_key_after_scale_parses;
          Alcotest.test_case "nested provider box tolerated" `Quick
            test_nested_provider_box_still_tolerated;
          Alcotest.test_case "provider box ends before generic key" `Quick
            test_target_provider_box_ends_before_generic_key;
          Alcotest.test_case "empty target value fails" `Quick
            test_empty_target_value_fails;
          Alcotest.test_case "target after resources fails" `Quick
            test_target_after_resources_fails;
          Alcotest.test_case "quoted hash survives" `Quick
            test_quoted_hash_survives;
          Alcotest.test_case "single quoted hash survives" `Quick
            test_single_quoted_hash_survives;
          Alcotest.test_case "malformed int fails" `Quick
            test_malformed_int_fails;
          Alcotest.test_case "malformed bool fails" `Quick
            test_malformed_bool_fails;
          Alcotest.test_case "root target defaults survive" `Quick
            test_root_target_defaults_survive;
          Alcotest.test_case "FEAT-028 shapes tolerated" `Quick
            test_feat_028_shapes_still_tolerated;
          Alcotest.test_case "provider box round trips" `Quick
            test_provider_box_round_trips;
          Alcotest.test_case "duplicate provider box fails" `Quick
            test_duplicate_provider_box_fails;
          Alcotest.test_case "unknown provider box fails" `Quick
            test_unknown_provider_box_fails;
          Alcotest.test_case "provider fields feed terraform vars" `Quick
            test_provider_fields_feed_active_terraform_provider;
          Alcotest.test_case "terraform vars: workspace_name + ecr_repositories"
            `Quick test_terraform_vars_workspace_name_and_ecr_repositories;
          Alcotest.test_case
            "terraform vars: ecr_repositories empty without app/" `Quick
            test_terraform_vars_ecr_repositories_empty_without_app_dir;
          Alcotest.test_case "example pluto prod target parses" `Quick
            test_example_pluto_prod_target_parses;
        ] );
    ]
