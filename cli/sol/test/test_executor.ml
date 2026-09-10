(* Tests for Sol_cli_executor.
   The local and direct executors call Sol_cli_manifest.apply which in
   dry_run=true mode only prints the YAML — no kubectl is invoked.
   The gitops executor writes a file to a temp directory. *)

(* ── fixtures ────────────────────────────────────────────────────────────── *)

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~workspace ~domain =
  Sol_cli_deployment_plan.namespace_of_exn ~workspace ~domain
;;

let cpu s =
  match Sol_cli_toml.cpu_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message
;;

let memory s =
  match Sol_cli_toml.memory_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message
;;

let svc_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~workspace:"myapp" ~domain:"payments"
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = "sol-registry:5000/myapp/charge-svc:abc123"
  ; config = []
  ; secrets = []
  ; volumes = []
  ; schedule = None
  ; replicas = 1
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

let worker_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "comms"
  ; source_name = "notify_worker"
  ; k8s_name = k8s_name "notify-worker"
  ; namespace = namespace ~workspace:"myapp" ~domain:"comms"
  ; primitive = Sol_cli_deployment_plan.Worker
  ; source_dir = "app/comms/notify_worker"
  ; image = "sol-registry:5000/myapp/notify-worker:abc123"
  ; config = []
  ; secrets = []
  ; volumes = []
  ; schedule = None
  ; replicas = 1
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

let check_string = Alcotest.(check string)

(* ── local executor ──────────────────────────────────────────────────────── *)

let test_local_result_fields () =
  (* dry_run=true exercises render+apply without invoking kubectl *)
  let r = Sol_cli_executor.local ~workspace:"myapp" ~dry_run:true svc_spec in
  check_string "local namespace" "myapp-payments" r.Sol_cli_executor.namespace;
  check_string "local name" "charge-svc" r.Sol_cli_executor.name;
  check_string
    "local image"
    "sol-registry:5000/myapp/charge-svc:abc123"
    r.Sol_cli_executor.image
;;

let test_local_worker_result () =
  let r = Sol_cli_executor.local ~workspace:"myapp" ~dry_run:true worker_spec in
  check_string "local worker namespace" "myapp-comms" r.Sol_cli_executor.namespace;
  check_string "local worker name" "notify-worker" r.Sol_cli_executor.name
;;

(* ── direct executor ─────────────────────────────────────────────────────── *)

let test_direct_result_fields () =
  let r = Sol_cli_executor.local ~workspace:"myapp" ~dry_run:true svc_spec in
  check_string "direct namespace" "myapp-payments" r.Sol_cli_executor.namespace;
  check_string "direct name" "charge-svc" r.Sol_cli_executor.name;
  check_string
    "direct image"
    "sol-registry:5000/myapp/charge-svc:abc123"
    r.Sol_cli_executor.image
;;

let test_direct_worker_result () =
  let r = Sol_cli_executor.local ~workspace:"myapp" ~dry_run:true worker_spec in
  check_string "direct worker namespace" "myapp-comms" r.Sol_cli_executor.namespace;
  check_string "direct worker name" "notify-worker" r.Sol_cli_executor.name
;;

(* ── gitops executor ─────────────────────────────────────────────────────── *)

let test_gitops_result_fields () =
  let dir = Filename.temp_file "sol-gitops-test-" "" in
  (* temp_file creates a regular file; we need a directory *)
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let r = Sol_cli_executor.gitops ~workspace:"myapp" ~dir svc_spec in
  check_string "gitops namespace" "myapp-payments" r.Sol_cli_executor.namespace;
  check_string "gitops name" "charge-svc" r.Sol_cli_executor.name;
  check_string
    "gitops image"
    "sol-registry:5000/myapp/charge-svc:abc123"
    r.Sol_cli_executor.image;
  (* clean up *)
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  (try Sys.remove path with
   | _ -> ());
  try Unix.rmdir dir with
  | _ -> ()
;;

let test_gitops_writes_file () =
  let dir = Filename.temp_file "sol-gitops-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  ignore (Sol_cli_executor.gitops ~workspace:"myapp" ~dir svc_spec);
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  let exists = Sys.file_exists path in
  (* read and check content before cleanup *)
  let content =
    if exists
    then (
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic;
      s)
    else ""
  in
  (try Sys.remove path with
   | _ -> ());
  (try Unix.rmdir dir with
   | _ -> ());
  Alcotest.(check bool) "gitops file created" true exists;
  Alcotest.(check bool)
    "gitops yaml has namespace"
    true
    (let needle = "name: myapp-payments" in
     let hl = String.length content
     and nl = String.length needle in
     let found = ref false in
     for i = 0 to hl - nl do
       if String.sub content i nl = needle then found := true
     done;
     !found)
;;

let test_gitops_worker () =
  let dir = Filename.temp_file "sol-gitops-worker-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let r = Sol_cli_executor.gitops ~workspace:"myapp" ~dir worker_spec in
  let path = Filename.concat dir "myapp-comms-notify-worker.yaml" in
  let exists = Sys.file_exists path in
  (try Sys.remove path with
   | _ -> ());
  (try Unix.rmdir dir with
   | _ -> ());
  check_string "gitops worker namespace" "myapp-comms" r.Sol_cli_executor.namespace;
  check_string "gitops worker name" "notify-worker" r.Sol_cli_executor.name;
  Alcotest.(check bool) "gitops worker file created" true exists
;;

(* ── entry point ─────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "executor"
    [ ( "local"
      , [ Alcotest.test_case "result fields (svc)" `Quick test_local_result_fields
        ; Alcotest.test_case "result fields (worker)" `Quick test_local_worker_result
        ] )
    ; ( "direct"
      , [ Alcotest.test_case "result fields (svc)" `Quick test_direct_result_fields
        ; Alcotest.test_case "result fields (worker)" `Quick test_direct_worker_result
        ] )
    ; ( "gitops"
      , [ Alcotest.test_case "result fields" `Quick test_gitops_result_fields
        ; Alcotest.test_case "file written" `Quick test_gitops_writes_file
        ; Alcotest.test_case "worker file written" `Quick test_gitops_worker
        ] )
    ]
;;
