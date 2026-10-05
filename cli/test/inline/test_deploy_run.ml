let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace:"myapp" ~domain with
  | Ok namespace -> namespace
  | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let quantity parse s =
  match parse s with
  | Ok q -> q
  | Error message -> Windtrap.fail message
;;

let spec ~domain ~name ~k8s primitive : Sol_cli_deployment_plan.service_spec =
  { domain
  ; source_name = name
  ; k8s_name = k8s_name k8s
  ; namespace = namespace ~domain
  ; primitive
  ; source_dir = "app/" ^ domain ^ "/" ^ name
  ; image = "registry.example.com/myapp/" ^ k8s ^ ":abc123"
  ; config = []
  ; secrets = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = quantity Sol_cli_toml.cpu_quantity_of_string "100m"
  ; memory = quantity Sol_cli_toml.memory_quantity_of_string "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

let release_id =
  Sol_cli_release_id.of_content
    { workspace = "myapp"; environment = None; workloads = []; contract = [] }
;;

let plan ?profile services : Sol_cli_deployment_plan.t =
  { workspace = "myapp"
  ; environment =
      { name = "myapp"
      ; mode = Sol_cli_deployment_plan.Customer_cloud
      ; registry = "registry.example.com"
      ; image_tag = "abc123"
      ; env = None
      ; region = None
      ; base_domain = None
      ; cluster_issuer = "letsencrypt-prod"
      ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
      }
  ; services
  ; topics = []
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  ; release_id
  ; requested_scope = "workspace"
  ; profile
  ; contract = []
  ; contract_changes = []
  }
;;

let production : Sol_cli_deployment_plan.profile_claim =
  { profile = Sol_cli_profile.Production_single_region
  ; requirements = []
  ; application_findings = []
  }
;;

let temp_dir () =
  let dir = Filename.temp_file "sol-deploy-run-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let with_context ?(migrations = []) f =
  let root = temp_dir () in
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir root;
       Out_channel.with_open_text "sol.yml" (fun oc ->
         output_string oc "project: myapp\n");
       Targets_fixture.write ~target:"dev/aws/us-east-1" "target:\n  cluster_name: c\n";
       if migrations <> []
       then (
         Unix.mkdir "db" 0o755;
         Unix.mkdir "db/migrations" 0o755;
         List.iter
           (fun name ->
              Out_channel.with_open_text (Filename.concat "db/migrations" name) (fun oc ->
                output_string oc "select 1;\n"))
           migrations);
       let config =
         match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
         | Ok config -> config
         | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
       in
       let facts =
         match Sol_cli_workspace_model.load ~root with
         | Ok facts -> facts
         | Error e -> Windtrap.fail e
       in
       let ctx : Sol_cli_deploy_run.context =
         { execution =
             Sol_cli_execution.context
               ~cluster:Sol_cli_kube_destination.local_context
               ~workspace:"myapp"
               ()
         ; sha = "abc123"
         ; registry = "registry.example.com"
         ; facts
         ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
         ; emit_plan_to = None
         ; target_cfg = config.target
         ; resolved_config = config
         ; services = []
         ; inventory = []
         ; image_refs = []
         ; requested_scope = "workspace"
         ; target_name = "dev/aws/us-east-1"
         ; run_log = Sol_cli_run_log.create ~base:(temp_dir ()) ~prefix:"deploy" ()
         ; keep_releases = 5
         }
       in
       f ctx)
;;

let gate ctx ~plan ~live =
  Sol_cli_report.collect (fun () ->
    Sol_cli_deploy_run.migration_prerequisite ctx ~plan ~live)
;;

let reported = List.map snd

let test_no_profile_is_not_checked () =
  with_context ~migrations:[ "001_init.sql" ] (fun ctx ->
    match gate ctx ~plan:(plan []) ~live:true with
    | Ok (), [] -> ()
    | Ok (), lines ->
      Windtrap.failf "unexpected report: %s" (String.concat "; " (reported lines))
    | Error _, _ -> Windtrap.fail "a deploy with no profile must not be gated")
;;

let test_offline_run_reports_not_verified () =
  with_context ~migrations:[ "001_init.sql" ] (fun ctx ->
    match gate ctx ~plan:(plan ~profile:production []) ~live:false with
    | Ok (), [ (_, line) ] ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"says NOT verified"
        true
        (Sol_cli_string.contains ~needle:"NOT verified" line)
    | Ok (), lines ->
      Windtrap.failf "expected one report, got: %s" (String.concat "; " (reported lines))
    | Error _, _ -> Windtrap.fail "an offline run must not fail the gate")
;;

let test_offline_run_without_migrations_says_nothing () =
  with_context (fun ctx ->
    match gate ctx ~plan:(plan ~profile:production []) ~live:false with
    | Ok (), [] -> ()
    | _ -> Windtrap.fail "no migrations: nothing to verify and nothing to say")
;;

let test_deploy_events_one_per_service () =
  with_context (fun ctx ->
    let deployment_id = Sol_cli_deployment_id.create ~now:0. ~entropy:"test" in
    let events =
      Sol_cli_deploy_run.deploy_events
        ~workspace:"myapp"
        ~target_cfg:ctx.target_cfg
        ~deployment_id
        (plan
           [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc
           ; spec ~domain:"comms" ~name:"notify_worker" ~k8s:"notify-worker" Worker
           ])
    in
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
      ~msg:"service and primitive"
      [ "charge-svc", "svc"; "notify-worker", "worker" ]
      (List.map (fun (e : Sol_cli_deploy_event.t) -> e.service, e.primitive) events);
    Windtrap.equal
      Windtrap.bool
      ~msg:"joined to the deployment"
      true
      (List.for_all
         (fun (e : Sol_cli_deploy_event.t) -> e.deployment_id = deployment_id)
         events);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the target's env"
      [ "dev"; "dev" ]
      (List.map (fun (e : Sol_cli_deploy_event.t) -> e.env) events))
;;

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try In_channel.with_open_text path In_channel.input_all with
  | Sys_error _ -> ""
;;

let fake_kubectl ~dir =
  Printf.sprintf
    {|#!/bin/sh
echo "$*" >> %s/calls.log
name=""
file=""
previous=""
for a in "$@"; do
  if [ "$previous" = "-f" ]; then file="$a"; fi
  case "$a" in
    sol-boundary-lease-*|sol-deploy-state-*|sol-release-current-*) name="$a" ;;
  esac
  previous="$a"
done
case " $* " in
  *" create "*|*" replace "*)
    if [ -n "$file" ] && grep -q sol-boundary-lease "$file" 2>/dev/null; then
      cp "$file" %s/lease.json
    fi
    exit 0
    ;;
esac
case "$name" in
  sol-boundary-lease-*)
    if [ -f %s/lease.json ]; then
      cat %s/lease.json
    else
      printf 'Error from server (NotFound): configmaps "lease" not found\n' >&2
      exit 1
    fi
    ;;
  sol-release-current-*)
    printf 'Error from server (NotFound): configmaps "current" not found\n' >&2
    exit 1
    ;;
  sol-deploy-state-*) printf 'alpha\nbravo' ;;
esac
exit 0
|}
    dir
    dir
    dir
    dir
;;

let with_fake_kubectl f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  write_file bin (fake_kubectl ~dir);
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () -> Unix.putenv "PATH" old_path)
    (fun () -> f ~calls:(fun () -> read_file (Filename.concat dir "calls.log")))
;;

let consumer_group_exn s =
  match Sol_cli_plan_ids.Consumer_group.of_string s with
  | Ok group -> group
  | Error message -> Windtrap.fail message
;;

let first_line_matching log needle =
  let lines = String.split_on_char '\n' log in
  let rec go index = function
    | [] -> None
    | line :: rest ->
      if Sol_cli_string.contains ~needle line then Some index else go (index + 1) rest
  in
  go 0 lines
;;

let test_the_group_check_reads_the_record_under_the_lease () =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      let notify =
        spec
          ~domain:"comms"
          ~name:"notify_worker"
          ~k8s:"notify-worker"
          Sol_cli_deployment_plan.Worker
      in
      let plan =
        { (plan [ notify ]) with
          consumer_groups = [ consumer_group_exn "myapp.comms.notify_worker" ]
        }
      in
      let outcome =
        Sol_cli_deploy_run.apply
          ctx
          ~prepare_plan:(fun _ -> Ok ())
          ~confirm_group_change:false
          ~push_events:(fun _ -> ())
          ~report_success:(fun _ _ -> ())
          plan
      in
      (match outcome with
       | Ok () ->
         Windtrap.fail
           "a record the plan no longer carries must refuse the deploy before it applies"
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the refusal names the groups the plan no longer carries"
           true
           (Sol_cli_string.contains ~needle:"no longer present" message));
      let log = calls () in
      let lease_at = first_line_matching log "sol-boundary-lease-myapp" in
      let recorded_at = first_line_matching log "sol-deploy-state-myapp" in
      let contract_at = first_line_matching log "sol-release-current-myapp" in
      (match lease_at, contract_at, recorded_at with
       | Some lease_at, Some contract_at, Some recorded_at ->
         Windtrap.equal
           Windtrap.bool
           true
           (lease_at < contract_at && contract_at < recorded_at)
       | _ ->
         Windtrap.failf
           "contract observation must run under the lease before the group guard:\n%s"
           log);

      (match lease_at, recorded_at with
       | Some lease_at, Some recorded_at ->
         Windtrap.equal
           Windtrap.bool
           ~msg:
             "the record is read only after the lease boundary is written, so an update \
              that landed in between cannot be missed"
           true
           (lease_at < recorded_at)
       | None, _ -> Windtrap.failf "the deploy never took its boundary lease:\n%s" log
       | _, None -> Windtrap.failf "the recorded groups were never read:\n%s" log);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and nothing was applied, because the check refused first"
        false
        (Sol_cli_string.contains ~needle:" apply " log)))
;;

let%test "migration gate (AUDIT-069): no profile" = test_no_profile_is_not_checked ()

let%test "migration gate (AUDIT-069): offline: not verified" =
  test_offline_run_reports_not_verified ()
;;

let%test "migration gate (AUDIT-069): offline: no migrations" =
  test_offline_run_without_migrations_says_nothing ()
;;

let%test "deploy events (FEAT-071): one per service" =
  test_deploy_events_one_per_service ()
;;

let%test "consumer-group guard (BUG-088): the record is read under the boundary lease" =
  test_the_group_check_reads_the_record_under_the_lease ()
;;

let%test "apply: a failed prepared-plan gate releases the lease before any workload mutation" =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      let outcome =
        Sol_cli_deploy_run.apply
          ctx
          ~prepare_plan:(fun _ -> Error "prerequisite refused")
          ~confirm_group_change:true
          ~push_events:(fun _ -> Windtrap.fail "a refused prerequisite emitted events")
          ~report_success:(fun _ _ -> Windtrap.fail "a refused prerequisite reported success")
          (plan [])
      in
      Windtrap.equal
        (Windtrap.result Windtrap.unit Windtrap.string)
        (Error "prerequisite refused")
        outcome;
      let log = calls () in
      Windtrap.equal Windtrap.bool false (Sol_cli_string.contains ~needle:" apply " log);
      Windtrap.equal Windtrap.bool true (Sol_cli_string.contains ~needle:" delete " log)))
;;
