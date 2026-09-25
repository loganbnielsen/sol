(* Offline tests for the destroy-path plan assertion (HARDEN-004 step 3).

   Every fixture is a Terraform *plan* representation (the shape `terraform show
   -json <saved plan>` emits) and every apply is a fake, so nothing here needs
   terraform or a cloud. The property that matters most is pinned twice: a plan
   the assertion refuses must never reach the apply. *)

open Sol_cli_terraform_plan

let plan_of changes =
  Printf.sprintf {|{"resource_changes":[%s]}|} (String.concat "," changes)
;;

let change ?(mode = "managed") address resource_type action =
  let action =
    Printf.sprintf "[%s]" (String.concat "," (List.map (Printf.sprintf "%S") action))
  in
  Printf.sprintf
    {|{"address":%S,"type":%S,"mode":%S,"change":{"actions":%s}}|}
    address
    resource_type
    mode
    action
;;

let create address kind = change address kind [ "create" ]
let update address kind = change address kind [ "update" ]
let delete address kind = change address kind [ "delete" ]
let replace address kind = change address kind [ "delete"; "create" ]
let no_op address kind = change address kind [ "no-op" ]
let data_read address kind = change ~mode:"data" address kind [ "read" ]

(* ── Policy fixtures ─────────────────────────────────────────────────────── *)

let binding =
  Sol_cli_terraform_plan.Exact
    "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
;;

let cluster = "google_container_cluster.main"
let sql = "google_sql_database_instance.postgres"
let network = "google_compute_network.main"

let allowlist policy json =
  match changes_of_plan_json json with
  | Error _ -> Alcotest.fail "fixture is not valid plan JSON"
  | Ok changes -> List.length (violations policy changes) = 0
;;

(* ── Parsing and classification ──────────────────────────────────────────── *)

let test_actions () =
  let check raw expected =
    let json = plan_of [ change "x.y" "z" raw ] in
    match changes_of_plan_json json with
    | Ok [ c ] ->
      Alcotest.(check string)
        ("action of " ^ String.concat "," raw)
        expected
        (action_to_string c.action)
    | _ -> Alcotest.failf "could not classify %s" (String.concat "," raw)
  in
  check [ "no-op" ] "no-op";
  check [ "read" ] "read";
  check [ "create" ] "create";
  check [ "update" ] "update";
  check [ "delete" ] "delete";
  check [ "delete"; "create" ] "replace";
  check [ "create"; "delete" ] "replace";
  check [ "frobnicate" ] "unrecognised action [frobnicate]"
;;

let test_malformed_is_error () =
  List.iter
    (fun json ->
       match changes_of_plan_json json with
       | Error _ -> ()
       | Ok _ -> Alcotest.failf "expected an error for %s" json)
    [ "not json"
    ; {|{"values":{}}|}
    ; {|{"resource_changes":{}}|}
    ; {|{"resource_changes":[{"type":"z","mode":"managed","change":{"actions":["create"]}}]}|}
      (* no address *)
    ]
;;

let test_empty_and_read_only_are_allowed () =
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  Alcotest.(check bool) "empty plan" true (allowlist policy (plan_of []));
  Alcotest.(check bool)
    "no-op anywhere"
    true
    (allowlist policy (plan_of [ no_op network network ]));
  Alcotest.(check bool)
    "data-source read"
    true
    (allowlist policy (plan_of [ data_read "data.x" "google_compute_network" ]))
;;

(* ── The phase allowlists ────────────────────────────────────────────────── *)

let test_whole_root_missing_cluster_create_is_refused () =
  (* Fixture 1: a whole-root-shaped plan whose missing cluster is a CREATE. *)
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  Alcotest.(check bool)
    "missing cluster create is refused"
    false
    (allowlist policy (plan_of [ create cluster "google_container_cluster" ]))
;;

let test_unrepresented_guarded_create_is_refused () =
  (* Fixture 2: preparing a guarded resource the inventory does not represent. *)
  let policy = Sol_cli_cloud_destroy.guard_preparation_policy ~addresses:[ cluster ] in
  Alcotest.(check bool)
    "configured-but-unrepresented guarded create is refused"
    false
    (allowlist policy (plan_of [ create cluster "google_container_cluster" ]))
;;

let test_unexpected_target_resource_create_is_refused () =
  (* Fixture 3: an unrelated target resource created by a destructive apply. *)
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  Alcotest.(check bool)
    "unexpected create is refused"
    false
    (allowlist policy (plan_of [ create network "google_compute_network" ]))
;;

let test_unexpected_replace_is_refused () =
  (* Fixture 4: ForceNew drift plans a replacement -- a create on the destroy path. *)
  let policy = Sol_cli_cloud_destroy.guard_preparation_policy ~addresses:[ cluster ] in
  Alcotest.(check bool)
    "replacement is refused"
    false
    (allowlist policy (plan_of [ replace cluster "google_container_cluster" ]))
;;

let test_bootstrap_create_is_allowed () =
  (* Fixture 5: the one constructive action destruction is allowed, and its plan
     must still be asserted. *)
  let policy = Sol_cli_cloud_destroy.bootstrap_enable_policy ~bootstrap:[ binding ] in
  Alcotest.(check bool)
    "bootstrap create is allowed"
    true
    (allowlist
       policy
       (plan_of
          [ create
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
          ]))
;;

let test_guarded_update_is_allowed () =
  (* Fixture 6: lowering a represented guarded resource's protection. *)
  let policy =
    Sol_cli_cloud_destroy.guard_preparation_policy ~addresses:[ cluster; sql ]
  in
  Alcotest.(check bool)
    "guarded update is allowed"
    true
    (allowlist
       policy
       (plan_of
          [ update cluster "google_container_cluster"
          ; update sql "google_sql_database_instance"
          ]))
;;

let test_removal_with_unexpected_create_is_refused () =
  (* Fixture 9: the bootstrap-access removal's plan is asserted too. *)
  let policy = Sol_cli_cloud_destroy.bootstrap_removal_policy ~bootstrap:[ binding ] in
  Alcotest.(check bool)
    "removal may not create target resources"
    false
    (allowlist
       policy
       (plan_of
          [ delete
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
          ; create cluster "google_container_cluster"
          ]));
  Alcotest.(check bool)
    "removal of the elevation is allowed"
    true
    (allowlist
       policy
       (plan_of
          [ delete
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
          ]));
  Alcotest.(check bool)
    "removal may not create the elevation it is closing"
    false
    (allowlist
       policy
       (plan_of
          [ create
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
          ]))
;;

let test_out_of_scope_delete_is_refused () =
  (* A delete of a resource outside the phase's scope is refused, so a plan can
     never quietly destroy something the phase does not own. *)
  let policy = Sol_cli_cloud_destroy.bootstrap_removal_policy ~bootstrap:[ binding ] in
  Alcotest.(check bool)
    "out-of-scope delete is refused"
    false
    (allowlist policy (plan_of [ delete network "google_compute_network" ]))
;;

let test_attempt6_inventory_prunes_the_scope () =
  (* Fixture 10: an Attempt-6-shaped inventory (network represented, cluster not)
     yields an empty guarded set, so a plan that reconstructs the missing cluster
     has no rule that could permit it. *)
  let inventory =
    {|{"values":{"root_module":{"resources":[{"address":"google_compute_network.main","type":"google_compute_network","values":{}}]}}}|}
  in
  match Sol_cli_cloud_destroy.inventory_of_show_json inventory with
  | Sol_cli_cloud_destroy.State_represented _ ->
    let eligible =
      Sol_cli_cloud_lifecycle.preparations_eligible
        ~state:
          (Sol_cli_cloud_destroy.addresses
             (Sol_cli_cloud_destroy.inventory_of_show_json inventory))
        ~desired:
          [ "google_container_cluster.main"; "google_sql_database_instance.postgres" ]
    in
    Alcotest.(check (list string)) "nothing guarded is eligible" [] eligible;
    let policy =
      Sol_cli_cloud_destroy.reconciliation_policy ~bootstrap:[ binding ] ~guarded:eligible
    in
    Alcotest.(check bool)
      "the missing cluster's create is refused"
      false
      (allowlist policy (plan_of [ create cluster "google_container_cluster" ]))
  | _ -> Alcotest.fail "expected a represented inventory"
;;

let test_unknown_action_is_refused () =
  let policy = Sol_cli_cloud_destroy.bootstrap_removal_policy ~bootstrap:[ binding ] in
  Alcotest.(check bool)
    "an unrecognised action is refused"
    false
    (allowlist
       policy
       (plan_of
          [ change
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
              [ "frobnicate" ]
          ]))
;;

(* ── guarded_apply: refusal must never reach the apply ───────────────────── *)

let guarded_apply_case ~plan_result ~plan_json =
  let applied = ref 0 in
  let policy =
    Sol_cli_terraform_plan.
      { phase = "test"
      ; rules = [ { matches = [ Exact cluster ]; allows = [ Update ]; reason = "" } ]
      }
  in
  let outcome =
    guarded_apply
      ~policy
      ~plan:(fun () -> plan_result)
      ~show_plan:(fun _ -> Ok plan_json)
      ~apply_plan:(fun _ ->
        applied := !applied + 1;
        Ok ())
      ()
  in
  outcome, !applied
;;

let test_guarded_apply_refusal_never_applies () =
  (* Fixtures 1/4/9's property, at the mechanism: refused means not applied. *)
  let outcome, applied =
    guarded_apply_case
      ~plan_result:(Ok "/tmp/plan")
      ~plan_json:(plan_of [ create cluster "google_container_cluster" ])
  in
  Alcotest.(check int) "the apply was never invoked" 0 applied;
  match outcome with
  | Error failure -> Alcotest.(check bool) "refused" true (was_refused failure)
  | Ok () -> Alcotest.fail "expected a refusal"
;;

let test_guarded_apply_malformed_never_applies () =
  (* Fixture 7: malformed/unreadable plan evidence. *)
  let outcome, applied =
    guarded_apply_case ~plan_result:(Ok "/tmp/plan") ~plan_json:"not json"
  in
  Alcotest.(check int) "the apply was never invoked" 0 applied;
  match outcome with
  | Error (Plan_unreadable _) -> ()
  | _ -> Alcotest.fail "expected Plan_unreadable"
;;

let test_guarded_apply_plan_failure_never_applies () =
  (* Fixture 8: the plan command itself failed. *)
  let outcome, applied =
    guarded_apply_case ~plan_result:(Error "terraform exited 1") ~plan_json:(plan_of [])
  in
  Alcotest.(check int) "the apply was never invoked" 0 applied;
  match outcome with
  | Error (Plan_failed _) -> ()
  | _ -> Alcotest.fail "expected Plan_failed"
;;

let test_guarded_apply_permitted_applies_once () =
  let outcome, applied =
    guarded_apply_case
      ~plan_result:(Ok "/tmp/plan")
      ~plan_json:(plan_of [ update cluster "google_container_cluster" ])
  in
  Alcotest.(check int) "the apply ran once" 1 applied;
  match outcome with
  | Ok () -> ()
  | Error failure ->
    Alcotest.failf "expected success: %s" (apply_failure_to_string failure)
;;

(* INFRA-074: the ECR repositories a cloud-apply plan would remove. A replace
   destroys the repository first, so it counts as a removal in both orderings. *)
let test_removed_of_type () =
  let changes =
    match
      changes_of_plan_json
        (plan_of
           [ delete {|aws_ecr_repository.services["old-svc"]|} "aws_ecr_repository"
           ; replace {|aws_ecr_repository.services["renamed"]|} "aws_ecr_repository"
           ; change
               {|aws_ecr_repository.services["create-first"]|}
               "aws_ecr_repository"
               [ "create"; "delete" ]
           ; update {|aws_ecr_repository.services["kept"]|} "aws_ecr_repository"
           ; create {|aws_ecr_repository.services["new-svc"]|} "aws_ecr_repository"
           ; delete "aws_ecr_lifecycle_policy.services" "aws_ecr_lifecycle_policy"
           ])
    with
    | Ok c -> c
    | Error e -> Alcotest.fail e
  in
  Alcotest.(check (list string))
    "deletes and replaces of the type, nothing else"
    [ {|aws_ecr_repository.services["old-svc"]|}
    ; {|aws_ecr_repository.services["renamed"]|}
    ; {|aws_ecr_repository.services["create-first"]|}
    ]
    (removed_of_type ~resource_type:"aws_ecr_repository" changes)
;;

(* SEC-008: `terraform show -json <plan>` carries sensitive values in plain text.
   show_and_record must record only the classified changes, never the JSON. *)
let secret = "s3cr3t-db-password-7f1c"

let plan_with_secret =
  Printf.sprintf
    {|{"variables":{"db_password":{"value":"%s"}},"resource_changes":[{"address":"aws_db_instance.main","type":"aws_db_instance","mode":"managed","change":{"actions":["delete"],"before":{"password":"%s"}}}]}|}
    secret
    secret
;;

let temp_dir () =
  let d = Filename.temp_file "sol-runlog-" "" in
  Sys.remove d;
  Unix.mkdir d 0o700;
  d
;;

let rec files_under dir =
  Array.to_list (Sys.readdir dir)
  |> List.concat_map (fun f ->
    let p = Filename.concat dir f in
    if Sys.is_directory p then files_under p else [ p ])
;;

let read path = In_channel.with_open_bin path In_channel.input_all

let contains ~needle s =
  let n = String.length needle
  and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = needle || go (i + 1)) in
  go 0
;;

let test_show_and_record_never_logs_plan_json () =
  let base = temp_dir () in
  let run_log = Sol_cli_run_log.create ~base ~prefix:"sec008" () in
  (match
     Sol_cli_terraform_plan.show_and_record
       ~run_log
       ~phase:"destroy-show"
       ~show:(fun () -> Ok plan_with_secret)
   with
   | Error m -> Alcotest.failf "unexpected error: %s" m
   | Ok (json, changes) ->
     Alcotest.(check string) "the JSON is returned to the caller" plan_with_secret json;
     Alcotest.(check int) "one change" 1 (List.length changes));
  let files = files_under base in
  Alcotest.(check bool) "a phase log was written" true (files <> []);
  List.iter
    (fun f ->
       Alcotest.(check bool)
         (Printf.sprintf "%s holds no secret" f)
         false
         (contains ~needle:secret (read f));
       Alcotest.(check int)
         (Printf.sprintf "%s is 0600" f)
         0o600
         ((Unix.stat f).st_perm land 0o777))
    files;
  Alcotest.(check bool)
    "the classified change is recorded"
    true
    (contains
       ~needle:"delete aws_db_instance.main"
       (read (Sol_cli_run_log.phase_log_path run_log ~phase:"destroy-show")))
;;

let test_show_and_record_unreadable_plan_is_an_error () =
  let run_log = Sol_cli_run_log.create ~base:(temp_dir ()) ~prefix:"sec008" () in
  Alcotest.(check bool)
    "malformed JSON refuses"
    true
    (Result.is_error
       (Sol_cli_terraform_plan.show_and_record
          ~run_log
          ~phase:"destroy-show"
          ~show:(fun () -> Ok "not json")));
  Alcotest.(check bool)
    "a failed show refuses"
    true
    (Result.is_error
       (Sol_cli_terraform_plan.show_and_record
          ~run_log
          ~phase:"destroy-show"
          ~show:(fun () -> Error "terraform exited 1")))
;;

(* ── The declared universe (FND-0055 / B2) ───────────────────────────────────
 *
 * `planned_values` is the declared set: the planned post-apply state, computed
 * by Terraform from the configuration. These cases pin that the extraction is
 * structural -- real addresses, child modules, indexed instances -- that it is
 * not the `resource_changes` create set, and that a document it cannot read is an
 * error rather than an empty result. *)

let plan_with_declared ?(changes = "[]") module_json =
  Printf.sprintf
    {|{"resource_changes":[%s],"planned_values":{"root_module":%s}}|}
    changes
    module_json
;;

let declared_resource ?(mode = "managed") address kind values =
  Printf.sprintf
    {|{"address":%S,"mode":%S,"type":%S,"values":%s}|}
    address
    mode
    kind
    values
;;

let declared_module ?(children = []) resources =
  Printf.sprintf
    {|{"resources":[%s],"child_modules":[%s]}|}
    (String.concat "," resources)
    (String.concat "," children)
;;

let declared_of ?(changes = "[]") module_json =
  match declared_of_plan_json (plan_with_declared ~changes module_json) with
  | Ok declared -> declared
  | Error message -> Alcotest.failf "the declared set could not be read: %s" message
;;

let declared_addresses declared = List.map (fun d -> d.address) declared

(* 1. A root managed resource appears, with Terraform's own address and values. *)
let test_declared_root_resource () =
  let declared =
    declared_of
      (declared_module
         [ declared_resource
             "google_compute_network.main"
             "google_compute_network"
             {|{"name":"sol-qual","project":"sol-qualification"}|}
         ])
  in
  Alcotest.(check (list string))
    "the root address"
    [ "google_compute_network.main" ]
    (declared_addresses declared);
  match declared with
  | [ d ] ->
    Alcotest.(check string) "the resource type" "google_compute_network" d.resource_type;
    Alcotest.(check string) "the mode" "managed" d.mode;
    Alcotest.(check (option string))
      "the planned values"
      (Some "sol-qual")
      (Yojson.Safe.Util.member "name" d.values |> Yojson.Safe.Util.to_string_option)
  | _ -> Alcotest.fail "expected exactly one declared resource"
;;

(* 2. A child-module resource keeps its real Terraform address. *)
let test_declared_child_module_address () =
  let declared =
    declared_of
      (declared_module
         []
         ~children:
           [ declared_module
               [ declared_resource
                   "module.platform.kubernetes_namespace.cert_manager"
                   "kubernetes_namespace"
                   {|{"metadata":[{"name":"cert-manager"}]}|}
               ]
           ])
  in
  Alcotest.(check (list string))
    "the child-module address is preserved"
    [ "module.platform.kubernetes_namespace.cert_manager" ]
    (declared_addresses declared)
;;

(* 3. Indexed / for_each instances stay distinct, at their real addresses. *)
let test_declared_indexed_instances () =
  let declared =
    declared_of
      (declared_module
         [ declared_resource
             {|google_compute_subnetwork.nodes["a"]|}
             "google_compute_subnetwork"
             {|{"name":"a"}|}
         ; declared_resource
             {|google_compute_subnetwork.nodes["b"]|}
             "google_compute_subnetwork"
             {|{"name":"b"}|}
         ])
  in
  Alcotest.(check (list string))
    "both instances, distinct"
    [ {|google_compute_subnetwork.nodes["a"]|}; {|google_compute_subnetwork.nodes["b"]|} ]
    (declared_addresses declared)
;;

(* 4. A data source is declared, but not owned: the caller excludes it by mode. *)
let test_declared_data_source_is_not_owned () =
  let declared =
    declared_of
      (declared_module
         [ declared_resource "google_compute_network.main" "google_compute_network" "{}"
         ; declared_resource
             ~mode:"data"
             "data.google_client_config.default"
             "google_client_config"
             "{}"
         ])
  in
  Alcotest.(check int) "both entries are read" 2 (List.length declared);
  Alcotest.(check (list string))
    "only the managed resource is a destruction obligation"
    [ "google_compute_network.main" ]
    (List.filter_map
       (fun d -> if String.equal d.mode "managed" then Some d.address else None)
       declared)
;;

(* 5. A represented no-op resource is declared even though it is not a change. *)
let test_declared_no_op_remains_declared () =
  let declared =
    declared_of
      ~changes:
        (String.concat
           ","
           [ no_op "google_container_cluster.main" "google_container_cluster" ])
      (declared_module
         [ declared_resource
             "google_container_cluster.main"
             "google_container_cluster"
             {|{"name":"sol-qual"}|}
         ])
  in
  Alcotest.(check (list string))
    "a no-op is still declared"
    [ "google_container_cluster.main" ]
    (declared_addresses declared)
;;

(* 6. CREATE is not the declared universe: the declared set comes from
   `planned_values`, so a create action neither adds nor removes an address. *)
let test_declared_universe_is_not_the_create_set () =
  let declared =
    declared_of
      ~changes:
        (String.concat
           ","
           [ create "google_container_cluster.main" "google_container_cluster" ])
      (declared_module
         [ declared_resource "google_compute_network.main" "google_compute_network" "{}" ])
  in
  Alcotest.(check (list string))
    "the shape-declared resource, not the create"
    [ "google_compute_network.main" ]
    (declared_addresses declared)
;;

(* 7. A document this cannot read fails closed -- never an empty declared set. *)
let test_declared_malformed_fails_closed () =
  List.iter
    (fun (label, json) ->
       Alcotest.(check bool)
         label
         true
         (Result.is_error (Sol_cli_terraform_plan.declared_of_plan_json json)))
    [ "invalid JSON", "{not json"
    ; "no planned_values", {|{"resource_changes":[]}|}
    ; "planned_values is not an object", {|{"planned_values":[]}|}
    ; "no root_module", {|{"planned_values":{}}|}
    ; "resources is not a list", {|{"planned_values":{"root_module":{"resources":{}}}}|}
    ; ( "a resource without a type"
      , {|{"planned_values":{"root_module":{"resources":[{"address":"a.b","mode":"managed"}]}}}|}
      )
    ]
;;

(* The provider block's own configuration, followed through the plan's resolved
   variables. A value it cannot read is [None] -- never a default. *)
let test_provider_value_from_the_plan () =
  let plan =
    {|{"variables":{"project_id":{"value":"sol-qualification"},"region":{"value":"us-central1"}},
       "configuration":{"provider_config":{"google":{"name":"google","expressions":{
         "project":{"references":["var.project_id"]},
         "region":{"references":["var.region"]},
         "zone":{"constant_value":"us-central1-a"}}}}}}|}
  in
  Alcotest.(check (option string))
    "a variable reference is resolved"
    (Some "sol-qualification")
    (provider_value ~json:plan ~provider:"google" ~key:"project");
  Alcotest.(check (option string))
    "and another"
    (Some "us-central1")
    (provider_value ~json:plan ~provider:"google" ~key:"region");
  Alcotest.(check (option string))
    "a literal is read"
    (Some "us-central1-a")
    (provider_value ~json:plan ~provider:"google" ~key:"zone");
  Alcotest.(check (option string))
    "a key the provider does not configure"
    None
    (provider_value ~json:plan ~provider:"google" ~key:"credentials");
  Alcotest.(check (option string))
    "another provider"
    None
    (provider_value ~json:plan ~provider:"aws" ~key:"region");
  Alcotest.(check (option string))
    "a document with no provider configuration"
    None
    (provider_value ~json:{|{}|} ~provider:"google" ~key:"project")
;;

(* SEC-008 applies to the declared read too: the plan document carries sensitive
   values in plain text, so only the declared addresses may reach the run log. *)
let test_show_declared_never_logs_plan_values () =
  let base = temp_dir () in
  let run_log = Sol_cli_run_log.create ~base ~prefix:"sec008-declared" () in
  let secret = "super-secret-db-password" in
  let plan =
    Printf.sprintf
      {|{"planned_values":{"root_module":{"resources":[
         {"address":"google_sql_database_instance.postgres","mode":"managed",
          "type":"google_sql_database_instance",
          "values":{"name":"sol-qual-postgres","root_password":%S}}
       ]}}}|}
      secret
  in
  (match
     Sol_cli_terraform_plan.show_declared_and_record
       ~run_log
       ~phase:"declared-universe-show"
       ~show:(fun () -> Ok plan)
   with
   | Error message -> Alcotest.failf "unexpected error: %s" message
   | Ok (json, declared) ->
     Alcotest.(check string) "the JSON is returned to the caller" plan json;
     Alcotest.(check (list string))
       "the declared address"
       [ "google_sql_database_instance.postgres" ]
       (List.map (fun d -> d.address) declared));
  let files = files_under base in
  Alcotest.(check bool) "a phase log was written" true (files <> []);
  List.iter
    (fun f ->
       Alcotest.(check bool)
         (Printf.sprintf "%s holds no plan value" f)
         false
         (contains ~needle:secret (read f)))
    files;
  Alcotest.(check bool)
    "the declared address is recorded"
    true
    (contains
       ~needle:"declared managed google_sql_database_instance.postgres"
       (read (Sol_cli_run_log.phase_log_path run_log ~phase:"declared-universe-show")))
;;

let () =
  Alcotest.run
    "terraform_plan"
    [ ( "classification"
      , [ Alcotest.test_case "actions" `Quick test_actions
        ; Alcotest.test_case "removed_of_type (INFRA-074)" `Quick test_removed_of_type
        ; Alcotest.test_case "malformed is an error" `Quick test_malformed_is_error
        ; Alcotest.test_case
            "empty and read-only are allowed"
            `Quick
            test_empty_and_read_only_are_allowed
        ; Alcotest.test_case
            "unknown action is refused"
            `Quick
            test_unknown_action_is_refused
        ] )
    ; ( "phase allowlists"
      , [ Alcotest.test_case
            "whole-root missing cluster create is refused"
            `Quick
            test_whole_root_missing_cluster_create_is_refused
        ; Alcotest.test_case
            "unrepresented guarded create is refused"
            `Quick
            test_unrepresented_guarded_create_is_refused
        ; Alcotest.test_case
            "unexpected target create is refused"
            `Quick
            test_unexpected_target_resource_create_is_refused
        ; Alcotest.test_case
            "unexpected replace is refused"
            `Quick
            test_unexpected_replace_is_refused
        ; Alcotest.test_case
            "bootstrap create is allowed"
            `Quick
            test_bootstrap_create_is_allowed
        ; Alcotest.test_case
            "guarded update is allowed"
            `Quick
            test_guarded_update_is_allowed
        ; Alcotest.test_case
            "removal with unexpected create is refused"
            `Quick
            test_removal_with_unexpected_create_is_refused
        ; Alcotest.test_case
            "out-of-scope delete is refused"
            `Quick
            test_out_of_scope_delete_is_refused
        ; Alcotest.test_case
            "Attempt-6 inventory prunes the scope"
            `Quick
            test_attempt6_inventory_prunes_the_scope
        ] )
    ; ( "guarded_apply"
      , [ Alcotest.test_case
            "refusal never applies"
            `Quick
            test_guarded_apply_refusal_never_applies
        ; Alcotest.test_case
            "malformed never applies"
            `Quick
            test_guarded_apply_malformed_never_applies
        ; Alcotest.test_case
            "plan failure never applies"
            `Quick
            test_guarded_apply_plan_failure_never_applies
        ; Alcotest.test_case
            "permitted applies once"
            `Quick
            test_guarded_apply_permitted_applies_once
        ] )
    ; ( "show_and_record (SEC-008)"
      , [ Alcotest.test_case
            "plan JSON never reaches the run log"
            `Quick
            test_show_and_record_never_logs_plan_json
        ; Alcotest.test_case
            "unreadable plan is an error"
            `Quick
            test_show_and_record_unreadable_plan_is_an_error
        ] )
    ; ( "the declared universe (B2)"
      , [ Alcotest.test_case
            "a root resource is declared"
            `Quick
            test_declared_root_resource
        ; Alcotest.test_case
            "a child module keeps its address"
            `Quick
            test_declared_child_module_address
        ; Alcotest.test_case
            "indexed instances stay distinct"
            `Quick
            test_declared_indexed_instances
        ; Alcotest.test_case
            "a data source is not owned"
            `Quick
            test_declared_data_source_is_not_owned
        ; Alcotest.test_case
            "a no-op is still declared"
            `Quick
            test_declared_no_op_remains_declared
        ; Alcotest.test_case
            "the declared set is not the create set"
            `Quick
            test_declared_universe_is_not_the_create_set
        ; Alcotest.test_case
            "malformed plan JSON fails closed"
            `Quick
            test_declared_malformed_fails_closed
        ; Alcotest.test_case
            "the provider configuration is read"
            `Quick
            test_provider_value_from_the_plan
        ; Alcotest.test_case
            "declared reads never log plan values (SEC-008)"
            `Quick
            test_show_declared_never_logs_plan_values
        ] )
    ]
;;
