let check_str = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let assert_error result =
  match result with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error but got Ok"
;;

let test_kubectl_apply_argv () =
  let c = Sol_cli_process.cmd [ "kubectl"; "apply"; "-f"; "/tmp/foo.yaml" ] in
  check_str "argv[0]" "kubectl" (List.nth c.argv 0);
  check_str "argv[1]" "apply" (List.nth c.argv 1);
  check_str "argv[3]" "/tmp/foo.yaml" (List.nth c.argv 3)
;;

let test_kubectl_apply_failure () =
  assert_error
    (Sol_cli_kubectl.apply
       ~ctx:Sol_cli_kube_destination.local_context
       ~file:"/nonexistent-path-zxqwerty.yaml")
;;

let test_kubectl_apply_dry_run_argv () =
  let c =
    Sol_cli_process.cmd [ "kubectl"; "apply"; "-f"; "x.yaml"; "--dry-run=server" ]
  in
  check_bool "has dry-run flag" true (List.mem "--dry-run=server" c.argv)
;;

let test_kubectl_get_argv () =
  let c =
    Sol_cli_process.cmd
      [ "kubectl"; "get"; "secret"; "my-secret"; "-n"; "default"; "-o"; "json" ]
  in
  check_str "resource" "secret" (List.nth c.argv 2);
  check_str "name" "my-secret" (List.nth c.argv 3);
  check_str "namespace" "default" (List.nth c.argv 5)
;;

let test_kubectl_get_failure () =
  assert_error
    (Sol_cli_kubectl.get
       ~ctx:Sol_cli_kube_destination.local_context
       ~resource:"pod"
       ~name:"nonexistent-abc123"
       ~namespace:"nonexistent-ns"
       ~output:"json")
;;

let test_kubectl_rollout_status_argv () =
  let c =
    Sol_cli_process.cmd
      [ "kubectl"; "rollout"; "status"; "deployment/my-svc"; "-n"; "staging" ]
  in
  check_str "subcommand" "rollout" (List.nth c.argv 1);
  check_str "action" "status" (List.nth c.argv 2);
  check_str "kind_name" "deployment/my-svc" (List.nth c.argv 3);
  check_str "namespace" "staging" (List.nth c.argv 5)
;;

let test_kubectl_rollout_restart_argv () =
  let c =
    Sol_cli_process.cmd [ "kubectl"; "rollout"; "restart"; "deployment"; "-n"; "ns" ]
  in
  check_str "action" "restart" (List.nth c.argv 2)
;;

let test_kubectl_create_job_from_cronjob_argv () =
  let c =
    Sol_cli_process.cmd
      [ "kubectl"
      ; "create"
      ; "job"
      ; "invoice-fn-manual-1700000000"
      ; "--from=cronjob/invoice-fn"
      ; "-n"
      ; "myapp-billing"
      ]
  in
  check_str "subcommand" "create" (List.nth c.argv 1);
  check_str "resource" "job" (List.nth c.argv 2);
  check_str "job name" "invoice-fn-manual-1700000000" (List.nth c.argv 3);
  check_str "--from=cronjob/" "--from=cronjob/invoice-fn" (List.nth c.argv 4);
  check_str "namespace" "myapp-billing" (List.nth c.argv 6)
;;

let test_kubectl_patch_argv () =
  let c =
    Sol_cli_process.cmd
      [ "kubectl"
      ; "patch"
      ; "secret"
      ; "my-secret"
      ; "-n"
      ; "default"
      ; "--type"
      ; "json"
      ; "-p"
      ; "[{}]"
      ]
  in
  check_str "resource" "secret" (List.nth c.argv 2);
  check_str "patch_type" "json" (List.nth c.argv 7);
  check_str "patch_data" "[{}]" (List.nth c.argv 9)
;;

let test_kubectl_classify () =
  let failed ?(stdout = "") stderr =
    Sol_cli_process.Non_zero { exit_code = 1; stdout; stderr }
  in
  let is expected message actual =
    Alcotest.(check bool) message true (Sol_cli_kubectl.classify actual = expected)
  in
  is
    Sol_cli_kubectl.Not_found
    "NotFound"
    (failed
       {|Error from server (NotFound): configmaps "sol-release-current-pluto" not found|});
  is
    Sol_cli_kubectl.Already_exists
    "AlreadyExists"
    (failed
       {|Error from server (AlreadyExists): namespaces "pluto-checkout" already exists|});
  is
    Sol_cli_kubectl.Conflict
    "Conflict"
    (failed
       {|Error from server (Conflict): error when replacing "/tmp/lease.json": Operation cannot be fulfilled on configmaps "sol-boundary-lease-pluto": the object has been modified; please apply your changes to the latest version and try again|});
  is
    Sol_cli_kubectl.No_resource_type
    "no CRD"
    (failed {|error: the server doesn't have a resource type "rollouts"|});
  is
    Sol_cli_kubectl.No_resource_type
    "no API group"
    (failed
       {|Error from server (NotFound): the server could not find the requested resource|});
  is
    Sol_cli_kubectl.Refused
    "unauthenticated"
    (failed {|error: You must be logged in to the server (Unauthorized)|});
  is
    Sol_cli_kubectl.Refused
    "forbidden"
    (failed
       {|Error from server (Forbidden): secrets is forbidden: User "x" cannot list resource "secrets"|});
  let unrelated =
    failed "Unable to connect to the server: net/http: TLS handshake timeout"
  in
  is Sol_cli_kubectl.Unreachable "no server to talk to" unrelated;
  let no_context = failed "error: current-context is not set" in
  is Sol_cli_kubectl.Unreachable "no kubeconfig context names a cluster" no_context;
  let no_server = failed {|error: no server found for cluster "sol-qualification"|} in
  is Sol_cli_kubectl.Unreachable "the kubeconfig names no server" no_server;
  let answered_but_sick =
    failed "error: the server is currently unable to handle the request"
  in
  is
    Sol_cli_kubectl.Other
    "a server that answered and refused to serve is not unreachable"
    answered_but_sick;
  let prose = failed "the configmap was NotFound in my notes" in
  is Sol_cli_kubectl.Other "a reason word in prose is not a reason" prose;
  let timeout = Sol_cli_process.Timeout 15. in
  is Sol_cli_kubectl.Other "timeout is Other" timeout;
  let kubectl_missing =
    Sol_cli_process.Spawn_failed "kubectl: No such file or directory"
  in
  is
    Sol_cli_kubectl.Other
    "a kubectl that could not run at all is not a cluster that cannot be reached"
    kubectl_missing;
  let forbidden =
    failed {|Error from server (Forbidden): secrets is forbidden: User "x" cannot get|}
  in
  Alcotest.(check bool)
    "the message keeps kubectl's words"
    true
    (Sol_cli_string.contains
       ~needle:{|secrets is forbidden: User "x" cannot get|}
       (Sol_cli_process.error_to_string forbidden))
;;

let test_kubectl_presence_classification () =
  let failed stderr =
    Sol_cli_kubectl.Failed { Sol_cli_process.exit_code = 1; stdout = ""; stderr }
  in
  let is_present = function
    | Sol_cli_kubectl.Present -> true
    | _ -> false
  in
  let is_absent = function
    | Sol_cli_kubectl.Absent _ -> true
    | _ -> false
  in
  let is_uncheckable = function
    | Sol_cli_kubectl.Uncheckable _ -> true
    | _ -> false
  in
  check_bool
    "zero exit is present"
    true
    (is_present (Sol_cli_kubectl.presence_of_probe_result (Ok Sol_cli_kubectl.Succeeded)));
  check_bool
    "non-zero exit is absent"
    true
    (is_absent
       (Sol_cli_kubectl.presence_of_probe_result
          (Ok (failed "Error from server (NotFound)"))));
  check_bool
    "an unrunnable kubectl is uncheckable"
    true
    (is_uncheckable
       (Sol_cli_kubectl.presence_of_probe_result (Error "kubectl could not be run")));
  check_bool
    "an unrunnable kubectl is not reported as absent"
    false
    (is_absent
       (Sol_cli_kubectl.presence_of_probe_result (Error "kubectl could not be run")));
  match
    Sol_cli_kubectl.presence_of_probe_result
      (Ok (failed "Error from server (NotFound): deployments not found"))
  with
  | Sol_cli_kubectl.Absent reason ->
    check_bool "the reason carries what kubectl said" true (String.length reason > 0)
  | _ -> Alcotest.fail "expected Absent for a non-zero exit"
;;

let test_docker_build_argv () =
  let c =
    Sol_cli_process.cmd
      [ "docker"; "build"; "-t"; "myimage:v1"; "-f"; "/ctx/svc/Dockerfile"; "/ctx" ]
  in
  check_str "argv[0]" "docker" (List.nth c.argv 0);
  check_str "argv[1]" "build" (List.nth c.argv 1);
  check_str "tag" "myimage:v1" (List.nth c.argv 3);
  check_str "dockerfile" "/ctx/svc/Dockerfile" (List.nth c.argv 5);
  check_str "context" "/ctx" (List.nth c.argv 6)
;;

let test_docker_push_argv () =
  let c = Sol_cli_process.cmd [ "docker"; "push"; "registry.example.com/myapp:v1" ] in
  check_str "argv[1]" "push" (List.nth c.argv 1);
  check_str "image_ref" "registry.example.com/myapp:v1" (List.nth c.argv 2)
;;

let test_docker_build_failure () =
  assert_error
    (Sol_cli_docker.build
       ~tag:"test:v0"
       ~dockerfile:"/nonexistent/Dockerfile"
       ~context:"/nonexistent")
;;

let test_docker_push_failure () =
  assert_error (Sol_cli_docker.push ~image_ref:"localhost:9999/nonexistent:nope")
;;

let test_docker_inspect_digest_fallback () =
  let fallback = Sol_cli_docker.inspect_digest ~image_ref:"nonexistent:image" in
  check_str "fallback is image_ref" "nonexistent:image" fallback
;;

let test_helm_repo_add_argv () =
  let c =
    Sol_cli_process.cmd
      [ "helm"; "repo"; "add"; "bitnami"; "https://charts.bitnami.com/bitnami" ]
  in
  check_str "argv[0]" "helm" (List.nth c.argv 0);
  check_str "argv[1]" "repo" (List.nth c.argv 1);
  check_str "argv[2]" "add" (List.nth c.argv 2);
  check_str "name" "bitnami" (List.nth c.argv 3);
  check_str "url" "https://charts.bitnami.com/bitnami" (List.nth c.argv 4)
;;

let test_helm_repo_update_argv () =
  let c = Sol_cli_process.cmd [ "helm"; "repo"; "update" ] in
  check_str "argv[2]" "update" (List.nth c.argv 2)
;;

let test_helm_upgrade_install_argv () =
  let c =
    Sol_cli_process.cmd
      ([ "helm"; "upgrade"; "--install"; "redpanda"; "redpanda/redpanda" ]
       @ [ "--namespace"; "redpanda"; "--create-namespace" ]
       @ [ "--set"; "tls.enabled=false" ]
       @ [ "--wait"; "--timeout"; "3m" ])
  in
  check_str "argv[1]" "upgrade" (List.nth c.argv 1);
  check_str "argv[2]" "--install" (List.nth c.argv 2);
  check_str "release" "redpanda" (List.nth c.argv 3);
  check_str "chart" "redpanda/redpanda" (List.nth c.argv 4);
  check_bool "has --create-namespace" true (List.mem "--create-namespace" c.argv);
  check_bool "has --wait" true (List.mem "--wait" c.argv)
;;

let test_helm_upgrade_install_version_argv () =
  let c =
    Sol_cli_process.cmd
      ([ "helm"; "upgrade"; "--install"; "loki"; "grafana-community/loki" ]
       @ [ "--namespace"; "monitoring"; "--create-namespace" ]
       @ [ "--version"; "18.12.1" ]
       @ [ "--wait"; "--timeout"; "3m" ])
  in
  check_str "argv[8]" "--version" (List.nth c.argv 8);
  check_str "argv[9]" "18.12.1" (List.nth c.argv 9)
;;

let test_helm_set_flags_bool () =
  let c =
    Sol_cli_process.cmd
      ([ "helm"; "upgrade"; "--install"; "r"; "c" ]
       @ [ "--namespace"; "ns"; "--create-namespace" ]
       @ [ "--set"; "tls.enabled=false" ]
       @ [ "--wait"; "--timeout"; "3m" ])
  in
  check_bool "has --set" true (List.mem "--set" c.argv)
;;

let test_helm_set_flags_str () =
  let c =
    Sol_cli_process.cmd
      ([ "helm"; "upgrade"; "--install"; "r"; "c" ]
       @ [ "--namespace"; "ns"; "--create-namespace" ]
       @ [ "--set-string"; "auth.password=dev" ]
       @ [ "--wait"; "--timeout"; "3m" ])
  in
  check_bool "has --set-string" true (List.mem "--set-string" c.argv)
;;

let test_terraform_init_argv () =
  let c = Sol_cli_process.cmd [ "terraform"; "-chdir=/some/dir"; "init" ] in
  check_str "argv[0]" "terraform" (List.nth c.argv 0);
  check_str "chdir" "-chdir=/some/dir" (List.nth c.argv 1);
  check_str "argv[2]" "init" (List.nth c.argv 2)
;;

let test_terraform_plan_argv () =
  let c =
    Sol_cli_process.cmd
      [ "terraform"
      ; "-chdir=/some/dir"
      ; "plan"
      ; "-var-file=prod.tfvars"
      ; "-var=cluster_name=sol-smoke"
      ]
  in
  check_str "argv[2]" "plan" (List.nth c.argv 2);
  check_bool "has var-file" true (List.mem "-var-file=prod.tfvars" c.argv);
  check_bool "has var" true (List.mem "-var=cluster_name=sol-smoke" c.argv)
;;

let test_terraform_plan_destroy_argv () =
  let c = Sol_cli_process.cmd [ "terraform"; "-chdir=/some/dir"; "plan"; "-destroy" ] in
  check_str "argv[2]" "plan" (List.nth c.argv 2);
  check_bool "has -destroy" true (List.mem "-destroy" c.argv)
;;

let test_terraform_apply_argv () =
  let c =
    Sol_cli_process.cmd [ "terraform"; "-chdir=/some/dir"; "apply"; "-auto-approve" ]
  in
  check_str "argv[2]" "apply" (List.nth c.argv 2);
  check_bool "has -auto-approve" true (List.mem "-auto-approve" c.argv)
;;

let test_terraform_destroy_argv () =
  let c =
    Sol_cli_process.cmd [ "terraform"; "-chdir=/some/dir"; "destroy"; "-auto-approve" ]
  in
  check_str "argv[2]" "destroy" (List.nth c.argv 2);
  check_bool "has -auto-approve" true (List.mem "-auto-approve" c.argv)
;;

let test_terraform_output_json_argv () =
  let c = Sol_cli_process.cmd [ "terraform"; "-chdir=/d"; "output"; "-json" ] in
  check_str "argv[2]" "output" (List.nth c.argv 2);
  check_str "argv[3]" "-json" (List.nth c.argv 3)
;;

let test_terraform_show_json_argv () =
  let c = Sol_cli_process.cmd [ "terraform"; "-chdir=/d"; "show"; "-json" ] in
  check_str "argv[2]" "show" (List.nth c.argv 2);
  check_str "argv[3]" "-json" (List.nth c.argv 3)
;;

let test_terraform_which_check_returns_bool () =
  let result = Sol_cli_terraform.which_check () in
  check_bool "returns a bool (true or false)" true (result || not result)
;;

let () =
  Alcotest.run
    "tool_adapters"
    [ ( "kubectl_argv"
      , [ Alcotest.test_case "apply argv" `Quick test_kubectl_apply_argv
        ; Alcotest.test_case "apply dry_run argv" `Quick test_kubectl_apply_dry_run_argv
        ; Alcotest.test_case "get argv" `Quick test_kubectl_get_argv
        ; Alcotest.test_case "rollout status argv" `Quick test_kubectl_rollout_status_argv
        ; Alcotest.test_case
            "rollout restart argv"
            `Quick
            test_kubectl_rollout_restart_argv
        ; Alcotest.test_case "patch argv" `Quick test_kubectl_patch_argv
        ; Alcotest.test_case
            "create job from cronjob argv"
            `Quick
            test_kubectl_create_job_from_cronjob_argv
        ] )
    ; ( "kubectl_failures"
      , [ Alcotest.test_case "apply propagates error" `Quick test_kubectl_apply_failure
        ; Alcotest.test_case "get propagates error" `Quick test_kubectl_get_failure
        ; Alcotest.test_case
            "probe presence classification"
            `Quick
            test_kubectl_presence_classification
        ; Alcotest.test_case "classify (REFAC-125)" `Quick test_kubectl_classify
        ] )
    ; ( "docker_argv"
      , [ Alcotest.test_case "build argv" `Quick test_docker_build_argv
        ; Alcotest.test_case "push argv" `Quick test_docker_push_argv
        ] )
    ; ( "docker_failures"
      , [ Alcotest.test_case "build propagates error" `Quick test_docker_build_failure
        ; Alcotest.test_case "push propagates error" `Quick test_docker_push_failure
        ; Alcotest.test_case
            "inspect digest fallback"
            `Quick
            test_docker_inspect_digest_fallback
        ] )
    ; ( "helm_argv"
      , [ Alcotest.test_case "repo add argv" `Quick test_helm_repo_add_argv
        ; Alcotest.test_case "repo update argv" `Quick test_helm_repo_update_argv
        ; Alcotest.test_case "upgrade install argv" `Quick test_helm_upgrade_install_argv
        ; Alcotest.test_case
            "upgrade install --version argv"
            `Quick
            test_helm_upgrade_install_version_argv
        ; Alcotest.test_case "set flags bool" `Quick test_helm_set_flags_bool
        ; Alcotest.test_case "set flags str" `Quick test_helm_set_flags_str
        ] )
    ; ( "terraform_argv"
      , [ Alcotest.test_case "init argv" `Quick test_terraform_init_argv
        ; Alcotest.test_case "plan argv" `Quick test_terraform_plan_argv
        ; Alcotest.test_case "plan destroy argv" `Quick test_terraform_plan_destroy_argv
        ; Alcotest.test_case "apply argv" `Quick test_terraform_apply_argv
        ; Alcotest.test_case "destroy argv" `Quick test_terraform_destroy_argv
        ; Alcotest.test_case "output json argv" `Quick test_terraform_output_json_argv
        ; Alcotest.test_case "show json argv" `Quick test_terraform_show_json_argv
        ; Alcotest.test_case
            "which_check returns bool"
            `Quick
            test_terraform_which_check_returns_bool
        ] )
    ]
;;
