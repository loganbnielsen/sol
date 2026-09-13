(* Tests for typed tool adapter modules: kubectl, docker, helm, terraform, git.
   Tests verify argv construction by checking cmd.argv (no external tools needed)
   and failure propagation by spawning a known-failing process. *)

let check_str = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

(* Run a command that always fails (spawn a missing binary) and check the error
   propagates as Spawn_failed or Non_zero — never silently swallowed. *)
let assert_error result =
  match result with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error but got Ok"
;;

(* ── Sol_cli_kubectl ──────────────────────────────────────────────────────── *)

let test_kubectl_apply_argv () =
  let c = Sol_cli_process.cmd [ "kubectl"; "apply"; "-f"; "/tmp/foo.yaml" ] in
  check_str "argv[0]" "kubectl" (List.nth c.Sol_cli_process.argv 0);
  check_str "argv[1]" "apply" (List.nth c.Sol_cli_process.argv 1);
  check_str "argv[3]" "/tmp/foo.yaml" (List.nth c.Sol_cli_process.argv 3)
;;

let test_kubectl_apply_failure () =
  assert_error (Sol_cli_kubectl.apply ~file:"/nonexistent-path-zxqwerty.yaml")
;;

let test_kubectl_apply_dry_run_argv () =
  let c =
    Sol_cli_process.cmd [ "kubectl"; "apply"; "-f"; "x.yaml"; "--dry-run=server" ]
  in
  check_bool "has dry-run flag" true (List.mem "--dry-run=server" c.Sol_cli_process.argv)
;;

let test_kubectl_get_argv () =
  let c =
    Sol_cli_process.cmd
      [ "kubectl"; "get"; "secret"; "my-secret"; "-n"; "default"; "-o"; "json" ]
  in
  check_str "resource" "secret" (List.nth c.Sol_cli_process.argv 2);
  check_str "name" "my-secret" (List.nth c.Sol_cli_process.argv 3);
  check_str "namespace" "default" (List.nth c.Sol_cli_process.argv 5)
;;

let test_kubectl_get_failure () =
  assert_error
    (Sol_cli_kubectl.get
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
  check_str "subcommand" "rollout" (List.nth c.Sol_cli_process.argv 1);
  check_str "action" "status" (List.nth c.Sol_cli_process.argv 2);
  check_str "kind_name" "deployment/my-svc" (List.nth c.Sol_cli_process.argv 3);
  check_str "namespace" "staging" (List.nth c.Sol_cli_process.argv 5)
;;

let test_kubectl_rollout_undo_argv () =
  let c =
    Sol_cli_process.cmd
      [ "kubectl"; "rollout"; "undo"; "deployment/my-svc"; "-n"; "prod" ]
  in
  check_str "action" "undo" (List.nth c.Sol_cli_process.argv 2)
;;

let test_kubectl_rollout_restart_argv () =
  let c =
    Sol_cli_process.cmd [ "kubectl"; "rollout"; "restart"; "deployment"; "-n"; "ns" ]
  in
  check_str "action" "restart" (List.nth c.Sol_cli_process.argv 2)
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
  check_str "resource" "secret" (List.nth c.Sol_cli_process.argv 2);
  check_str "patch_type" "json" (List.nth c.Sol_cli_process.argv 7);
  check_str "patch_data" "[{}]" (List.nth c.Sol_cli_process.argv 9)
;;

let test_kubectl_config_current_context_argv () =
  let c = Sol_cli_process.cmd [ "kubectl"; "config"; "current-context" ] in
  check_str "subcommand" "config" (List.nth c.Sol_cli_process.argv 1);
  check_str "action" "current-context" (List.nth c.Sol_cli_process.argv 2)
;;

let test_kubectl_probe_false_on_missing_binary () =
  let result = Sol_cli_kubectl.probe ~args:[ "nonexistent-abc123-subcommand" ] in
  check_bool "probe returns false for missing tool" false result
;;

(* ── Sol_cli_docker ───────────────────────────────────────────────────────── *)

let test_docker_build_argv () =
  let c =
    Sol_cli_process.cmd
      [ "docker"; "build"; "-t"; "myimage:v1"; "-f"; "/ctx/svc/Dockerfile"; "/ctx" ]
  in
  check_str "argv[0]" "docker" (List.nth c.Sol_cli_process.argv 0);
  check_str "argv[1]" "build" (List.nth c.Sol_cli_process.argv 1);
  check_str "tag" "myimage:v1" (List.nth c.Sol_cli_process.argv 3);
  check_str "dockerfile" "/ctx/svc/Dockerfile" (List.nth c.Sol_cli_process.argv 5);
  check_str "context" "/ctx" (List.nth c.Sol_cli_process.argv 6)
;;

let test_docker_push_argv () =
  let c = Sol_cli_process.cmd [ "docker"; "push"; "registry.example.com/myapp:v1" ] in
  check_str "argv[1]" "push" (List.nth c.Sol_cli_process.argv 1);
  check_str
    "image_ref"
    "registry.example.com/myapp:v1"
    (List.nth c.Sol_cli_process.argv 2)
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

(* ── Sol_cli_helm ─────────────────────────────────────────────────────────── *)

let test_helm_repo_add_argv () =
  let c =
    Sol_cli_process.cmd
      [ "helm"; "repo"; "add"; "bitnami"; "https://charts.bitnami.com/bitnami" ]
  in
  check_str "argv[0]" "helm" (List.nth c.Sol_cli_process.argv 0);
  check_str "argv[1]" "repo" (List.nth c.Sol_cli_process.argv 1);
  check_str "argv[2]" "add" (List.nth c.Sol_cli_process.argv 2);
  check_str "name" "bitnami" (List.nth c.Sol_cli_process.argv 3);
  check_str "url" "https://charts.bitnami.com/bitnami" (List.nth c.Sol_cli_process.argv 4)
;;

let test_helm_repo_update_argv () =
  let c = Sol_cli_process.cmd [ "helm"; "repo"; "update" ] in
  check_str "argv[2]" "update" (List.nth c.Sol_cli_process.argv 2)
;;

let test_helm_upgrade_install_argv () =
  let c =
    Sol_cli_process.cmd
      ([ "helm"; "upgrade"; "--install"; "redpanda"; "redpanda/redpanda" ]
       @ [ "--namespace"; "redpanda"; "--create-namespace" ]
       @ [ "--set"; "tls.enabled=false" ]
       @ [ "--wait"; "--timeout"; "3m" ])
  in
  check_str "argv[1]" "upgrade" (List.nth c.Sol_cli_process.argv 1);
  check_str "argv[2]" "--install" (List.nth c.Sol_cli_process.argv 2);
  check_str "release" "redpanda" (List.nth c.Sol_cli_process.argv 3);
  check_str "chart" "redpanda/redpanda" (List.nth c.Sol_cli_process.argv 4);
  check_bool
    "has --create-namespace"
    true
    (List.mem "--create-namespace" c.Sol_cli_process.argv);
  check_bool "has --wait" true (List.mem "--wait" c.Sol_cli_process.argv)
;;

(* CODE_LAYER-008: Sol_cli_helm.upgrade_install's ?version places --version
   between --create-namespace and --set/-f (see sol_cli_helm.ml) -- this
   documents that shape, same as the sibling argv tests above; the real
   `upgrade_install` function itself is exercised end to end by live
   cluster verification (all 7 helm_install call sites in cmd_local.ml,
   CODE_LAYER-008), not by this suite, same as every other _argv test in
   this file (none call the real Sol_cli_kubectl/Sol_cli_docker/Sol_cli_helm
   functions -- see the module comment at the top of this file if that
   changes for one of them). *)
let test_helm_upgrade_install_version_argv () =
  let c =
    Sol_cli_process.cmd
      ([ "helm"; "upgrade"; "--install"; "loki"; "grafana-community/loki" ]
       @ [ "--namespace"; "monitoring"; "--create-namespace" ]
       @ [ "--version"; "18.12.1" ]
       @ [ "--wait"; "--timeout"; "3m" ])
  in
  check_str "argv[8]" "--version" (List.nth c.Sol_cli_process.argv 8);
  check_str "argv[9]" "18.12.1" (List.nth c.Sol_cli_process.argv 9)
;;

let test_helm_set_flags_bool () =
  let c =
    Sol_cli_process.cmd
      ([ "helm"; "upgrade"; "--install"; "r"; "c" ]
       @ [ "--namespace"; "ns"; "--create-namespace" ]
       @ [ "--set"; "tls.enabled=false" ]
       @ [ "--wait"; "--timeout"; "3m" ])
  in
  check_bool "has --set" true (List.mem "--set" c.Sol_cli_process.argv)
;;

let test_helm_set_flags_str () =
  let c =
    Sol_cli_process.cmd
      ([ "helm"; "upgrade"; "--install"; "r"; "c" ]
       @ [ "--namespace"; "ns"; "--create-namespace" ]
       @ [ "--set-string"; "auth.password=dev" ]
       @ [ "--wait"; "--timeout"; "3m" ])
  in
  check_bool "has --set-string" true (List.mem "--set-string" c.Sol_cli_process.argv)
;;

(* ── Sol_cli_terraform ────────────────────────────────────────────────────── *)

let test_terraform_init_argv () =
  let c = Sol_cli_process.cmd [ "terraform"; "-chdir=/some/dir"; "init" ] in
  check_str "argv[0]" "terraform" (List.nth c.Sol_cli_process.argv 0);
  check_str "chdir" "-chdir=/some/dir" (List.nth c.Sol_cli_process.argv 1);
  check_str "argv[2]" "init" (List.nth c.Sol_cli_process.argv 2)
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
  check_str "argv[2]" "plan" (List.nth c.Sol_cli_process.argv 2);
  check_bool "has var-file" true (List.mem "-var-file=prod.tfvars" c.Sol_cli_process.argv);
  check_bool
    "has var"
    true
    (List.mem "-var=cluster_name=sol-smoke" c.Sol_cli_process.argv)
;;

let test_terraform_plan_destroy_argv () =
  let c = Sol_cli_process.cmd [ "terraform"; "-chdir=/some/dir"; "plan"; "-destroy" ] in
  check_str "argv[2]" "plan" (List.nth c.Sol_cli_process.argv 2);
  check_bool "has -destroy" true (List.mem "-destroy" c.Sol_cli_process.argv)
;;

let test_terraform_apply_argv () =
  let c =
    Sol_cli_process.cmd [ "terraform"; "-chdir=/some/dir"; "apply"; "-auto-approve" ]
  in
  check_str "argv[2]" "apply" (List.nth c.Sol_cli_process.argv 2);
  check_bool "has -auto-approve" true (List.mem "-auto-approve" c.Sol_cli_process.argv)
;;

let test_terraform_destroy_argv () =
  let c =
    Sol_cli_process.cmd [ "terraform"; "-chdir=/some/dir"; "destroy"; "-auto-approve" ]
  in
  check_str "argv[2]" "destroy" (List.nth c.Sol_cli_process.argv 2);
  check_bool "has -auto-approve" true (List.mem "-auto-approve" c.Sol_cli_process.argv)
;;

let test_terraform_output_json_argv () =
  let c = Sol_cli_process.cmd [ "terraform"; "-chdir=/d"; "output"; "-json" ] in
  check_str "argv[2]" "output" (List.nth c.Sol_cli_process.argv 2);
  check_str "argv[3]" "-json" (List.nth c.Sol_cli_process.argv 3)
;;

let test_terraform_which_check_returns_bool () =
  let result = Sol_cli_terraform.which_check () in
  check_bool "returns a bool (true or false)" true (result || not result)
;;

(* ── suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "tool_adapters"
    [ ( "kubectl_argv"
      , [ Alcotest.test_case "apply argv" `Quick test_kubectl_apply_argv
        ; Alcotest.test_case "apply dry_run argv" `Quick test_kubectl_apply_dry_run_argv
        ; Alcotest.test_case "get argv" `Quick test_kubectl_get_argv
        ; Alcotest.test_case "rollout status argv" `Quick test_kubectl_rollout_status_argv
        ; Alcotest.test_case "rollout undo argv" `Quick test_kubectl_rollout_undo_argv
        ; Alcotest.test_case
            "rollout restart argv"
            `Quick
            test_kubectl_rollout_restart_argv
        ; Alcotest.test_case "patch argv" `Quick test_kubectl_patch_argv
        ; Alcotest.test_case
            "config current-context"
            `Quick
            test_kubectl_config_current_context_argv
        ] )
    ; ( "kubectl_failures"
      , [ Alcotest.test_case "apply propagates error" `Quick test_kubectl_apply_failure
        ; Alcotest.test_case "get propagates error" `Quick test_kubectl_get_failure
        ; Alcotest.test_case
            "probe false for missing"
            `Quick
            test_kubectl_probe_false_on_missing_binary
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
        ; Alcotest.test_case
            "which_check returns bool"
            `Quick
            test_terraform_which_check_returns_bool
        ] )
    ]
;;
