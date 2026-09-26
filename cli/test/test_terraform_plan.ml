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

(* The authority mechanism exactly as the GCP capability declares it. It is a
   `count`-indexed root-level resource, so Terraform's plan address for it is
   always `...[0]` -- never the bare declaration. Every authority fixture below
   therefore exercises the *index-qualified* addresses a real plan carries; the
   un-indexed form is included only for completeness. A fixture built from the
   declaration's own string, as this file used to do, cannot detect the defect
   that made Attempt 8's destroy refuse its own authority create (FND-0058). *)
let authority = "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"

(* Every address shape a real plan can carry for the declared resource, plus the
   shapes it must *not* match. *)
let authority_instances =
  [ authority; authority ^ "[0]"; authority ^ "[37]"; authority ^ "[\"key\"]" ]
;;

let not_the_authority =
  [ authority ^ "_suffix"
  ; authority ^ ".extra"
  ; "module.other." ^ authority
  ; "module.platform." ^ authority ^ "[0]"
  ; "kubernetes_cluster_role_binding.other_binding"
  ; "kubernetes_cluster_role_binding.other_binding[0]"
  ; "google_container_cluster.main[0]"
  ]
;;

let binding = Sol_cli_terraform_plan.Resource authority
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

(* FND-0058. The declaration names a resource; the plan names an instance. Both
   halves are tested separately -- the matcher decides identity, the policy
   decides permission -- and the first test is the regression Attempt 8 needs:
   the index-qualified create must be *accepted* by the reconciliation that
   exists to acquire the authority. *)
let test_declared_authority_matches_every_instance () =
  let policy = Sol_cli_cloud_destroy.bootstrap_enable_policy ~bootstrap:[ binding ] in
  List.iter
    (fun address ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is the declared authority resource" address)
         true
         (allowlist policy (plan_of [ create address "kubernetes_cluster_role_binding" ])))
    authority_instances
;;

let test_declared_authority_matches_nothing_else () =
  let policy = Sol_cli_cloud_destroy.bootstrap_enable_policy ~bootstrap:[ binding ] in
  List.iter
    (fun address ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is not the declared authority resource" address)
         false
         (allowlist policy (plan_of [ create address "kubernetes_cluster_role_binding" ])))
    not_the_authority
;;

let test_attempt8_authority_create_is_accepted () =
  (* The exact Attempt-8 plan: one CREATE, on the index-qualified authority
     resource, asserted by the reconciliation policy. This is the assertion the
     old `Exact` declaration could never satisfy. *)
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  Alcotest.(check bool)
    "index-qualified authority create is accepted"
    true
    (allowlist
       policy
       (plan_of [ create (authority ^ "[0]") "kubernetes_cluster_role_binding" ]));
  Alcotest.(check bool)
    "index-qualified authority update is accepted"
    true
    (allowlist
       policy
       (plan_of [ update (authority ^ "[0]") "kubernetes_cluster_role_binding" ]));
  Alcotest.(check bool)
    "a for_each-keyed authority create is accepted"
    true
    (allowlist
       policy
       (plan_of [ create (authority ^ "[\"key\"]") "kubernetes_cluster_role_binding" ]))
;;

let test_attempt8_authority_create_is_refused_where_the_action_is_forbidden () =
  (* Identity is not permission: the same instance-qualified change is refused by
     the *removal* policy, whose rule for the same resource allows Update/Delete
     only. *)
  let policy = Sol_cli_cloud_destroy.bootstrap_removal_policy ~bootstrap:[ binding ] in
  Alcotest.(check bool)
    "removal may not create the authority it just removed"
    false
    (allowlist
       policy
       (plan_of [ create (authority ^ "[0]") "kubernetes_cluster_role_binding" ]));
  Alcotest.(check bool)
    "removal may delete it"
    true
    (allowlist
       policy
       (plan_of [ delete (authority ^ "[0]") "kubernetes_cluster_role_binding" ]))
;;

let test_indexed_sibling_create_is_still_refused () =
  (* The precision that makes the fix safe: another ClusterRoleBinding, indexed
     or not, is not the declared authority and stays refused. This is the
     negative control a `Type` matcher would fail. *)
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  List.iter
    (fun address ->
       Alcotest.(check bool)
         (Printf.sprintf "an unrelated %s create is refused" address)
         false
         (allowlist policy (plan_of [ create address "kubernetes_cluster_role_binding" ])))
    [ "kubernetes_cluster_role_binding.other_binding[0]"
    ; "module.platform." ^ authority ^ "[0]"
    ]
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
            "declared authority matches every instance"
            `Quick
            test_declared_authority_matches_every_instance
        ; Alcotest.test_case
            "declared authority matches nothing else"
            `Quick
            test_declared_authority_matches_nothing_else
        ; Alcotest.test_case
            "Attempt-8 authority create is accepted"
            `Quick
            test_attempt8_authority_create_is_accepted
        ; Alcotest.test_case
            "Attempt-8 authority create is refused where the action is forbidden"
            `Quick
            test_attempt8_authority_create_is_refused_where_the_action_is_forbidden
        ; Alcotest.test_case
            "indexed sibling create is still refused"
            `Quick
            test_indexed_sibling_create_is_still_refused
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
    ]
;;
