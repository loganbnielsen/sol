let ok = function
  | Ok r -> r
  | Error e -> Alcotest.fail e
;;

let release_id_of_test =
  Sol_cli_release_id.of_content { workspace = "test"; environment = None; workloads = [] }
;;

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> namespace
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
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
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
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

let worker_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "comms"
  ; source_name = "notify_worker"
  ; k8s_name = k8s_name "notify-worker"
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; namespace = namespace ~workspace:"myapp" ~domain:"comms"
  ; primitive = Sol_cli_deployment_plan.Worker
  ; source_dir = "app/comms/notify_worker"
  ; image = "sol-registry:5000/myapp/notify-worker:abc123"
  ; config = []
  ; secrets = []
  ; volumes = []
  ; schedule = None
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
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

let check_string = Alcotest.(check string)

let test_local_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      svc_spec
    |> ok
  in
  check_string "local namespace" "myapp-payments" r.namespace;
  check_string "local name" "charge-svc" r.name;
  check_string "local image" "sol-registry:5000/myapp/charge-svc:abc123" r.image
;;

let test_local_worker_result () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      worker_spec
    |> ok
  in
  check_string "local worker namespace" "myapp-comms" r.namespace;
  check_string "local worker name" "notify-worker" r.name
;;

let test_direct_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      svc_spec
    |> ok
  in
  check_string "direct namespace" "myapp-payments" r.namespace;
  check_string "direct name" "charge-svc" r.name;
  check_string "direct image" "sol-registry:5000/myapp/charge-svc:abc123" r.image
;;

let test_direct_worker_result () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      worker_spec
    |> ok
  in
  check_string "direct worker namespace" "myapp-comms" r.namespace;
  check_string "direct worker name" "notify-worker" r.name
;;

let test_gitops_result_fields () =
  let dir = Filename.temp_file "sol-gitops-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let r =
    Sol_cli_executor.gitops
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dir
      svc_spec
    |> ok
  in
  check_string "gitops namespace" "myapp-payments" r.namespace;
  check_string "gitops name" "charge-svc" r.name;
  check_string "gitops image" "sol-registry:5000/myapp/charge-svc:abc123" r.image;
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
  ignore
    (Sol_cli_executor.gitops
       ~ctx:Sol_cli_kube_destination.local_context
       ~workspace:"myapp"
       ~release_id:release_id_of_test
       ~dir
       svc_spec);
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  let exists = Sys.file_exists path in
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
  let r =
    Sol_cli_executor.gitops
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dir
      worker_spec
    |> ok
  in
  let path = Filename.concat dir "myapp-comms-notify-worker.yaml" in
  let exists = Sys.file_exists path in
  (try Sys.remove path with
   | _ -> ());
  (try Unix.rmdir dir with
   | _ -> ());
  check_string "gitops worker namespace" "myapp-comms" r.namespace;
  check_string "gitops worker name" "notify-worker" r.name;
  Alcotest.(check bool) "gitops worker file created" true exists
;;

let read_file path =
  let ic = open_in path in
  let content = In_channel.input_all ic in
  close_in ic;
  content
;;

let contains needle haystack =
  let nlen = String.length needle
  and hlen = String.length haystack in
  let found = ref false in
  for i = 0 to hlen - nlen do
    if (not !found) && String.sub haystack i nlen = needle then found := true
  done;
  !found
;;

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let remove_dir dir name =
  (try Sys.remove (Filename.concat dir name) with
   | _ -> ());
  try Unix.rmdir dir with
  | _ -> ()
;;

let secretful_spec : Sol_cli_deployment_plan.service_spec =
  { svc_spec with secrets = [ "DATABASE_URL", ""; "API_KEY", "" ] }
;;

let external_secrets_backend =
  Sol_cli_manifest.External_secrets
    { store_ref = "probe-store"
    ; store_kind = "ClusterSecretStore"
    ; key_prefix = "myapp/"
    ; refresh_interval = "1h"
    }
;;

let emitted_name = "myapp-payments-charge-svc.yaml"

let test_gitops_preserves_external_secrets () =
  let dir = temp_dir "sol-gitops-eso-" in
  (match
     Sol_cli_executor.gitops
       ~ctx:Sol_cli_kube_destination.local_context
       ~workspace:"myapp"
       ~release_id:release_id_of_test
       ~dir
       ~secret_backend:external_secrets_backend
       secretful_spec
   with
   | Error e -> Alcotest.fail ("gitops emission failed: " ^ e)
   | Ok _ -> ());
  let content = read_file (Filename.concat dir emitted_name) in
  remove_dir dir emitted_name;
  Alcotest.(check bool)
    "An ExternalSecret is emitted, not a plain Secret"
    true
    (contains "kind: ExternalSecret" content);
  Alcotest.(check bool) "store reference preserved" true (contains "probe-store" content);
  Alcotest.(check bool)
    "key prefix preserved"
    true
    (contains "key: myapp/DATABASE_URL" content);
  Alcotest.(check bool)
    "refresh interval preserved"
    true
    (contains "refreshInterval: 1h" content);
  Alcotest.(check bool) "no plaintext Secret" false (contains "kind: Secret" content)
;;

let test_gitops_rejects_kubernetes_live () =
  let dir = temp_dir "sol-gitops-live-" in
  let outcome =
    Sol_cli_executor.gitops
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dir
      ~secret_backend:Sol_cli_manifest.Kubernetes_live
      secretful_spec
  in
  let written = Sys.file_exists (Filename.concat dir emitted_name) in
  remove_dir dir emitted_name;
  (match outcome with
   | Error message ->
     Alcotest.(check bool) "names the refusal" true (contains "kubernetes-live" message)
   | Ok _ -> Alcotest.fail "kubernetes-live must not emit a GitOps artifact");
  Alcotest.(check bool) "nothing was written" false written
;;

let test_gitops_placeholder_still_emits_secret () =
  let dir = temp_dir "sol-gitops-placeholder-" in
  (match
     Sol_cli_executor.gitops
       ~ctx:Sol_cli_kube_destination.local_context
       ~workspace:"myapp"
       ~release_id:release_id_of_test
       ~dir
       ~secret_backend:Sol_cli_manifest.Kubernetes_placeholder
       secretful_spec
   with
   | Error e -> Alcotest.fail ("gitops emission failed: " ^ e)
   | Ok _ -> ());
  let content = read_file (Filename.concat dir emitted_name) in
  remove_dir dir emitted_name;
  Alcotest.(check bool)
    "placeholder Secret emitted"
    true
    (contains "kind: Secret" content);
  Alcotest.(check bool)
    "no ExternalSecret"
    false
    (contains "kind: ExternalSecret" content)
;;

let with_secretless_kubectl f =
  let dir = temp_dir "sol-executor-kubectl-" in
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "kubectl" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
verb=""
kind=""
next=0
for a in "$@"; do
  case "$a" in
    apply|create|patch) [ -z "$verb" ] && verb="$a" ;;
    get) [ -z "$verb" ] && verb="get" && next=1 ;;
    *) if [ "$next" = 1 ]; then kind="$a"; next=0; fi ;;
  esac
done
printf '%%s %%s\n' "$verb" "$kind" >> %s
if [ "$verb" = "get" ] && [ "$kind" = "secret" ]; then
  echo 'Error from server (NotFound): secrets "charge-svc-secrets" not found' >&2
  exit 1
fi
exit 0
|}
      log
  in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f ~calls:(fun () -> read_file log))
;;

let test_apply_fails_closed_when_the_workload_secret_is_absent () =
  with_secretless_kubectl (fun ~calls ->
    let outcome =
      Sol_cli_executor.local
        ~ctx:Sol_cli_kube_destination.local_context
        ~workspace:"myapp"
        ~release_id:release_id_of_test
        ~dry_run:false
        svc_spec
    in
    (match outcome with
     | Error message ->
       Alcotest.(check bool)
         "names the missing required key"
         true
         (contains "POSTGRES_URL" message);
       Alcotest.(check bool)
         "says deploy never writes values"
         true
         (contains "never write values" message)
     | Ok _ -> Alcotest.fail "apply must fail closed when the workload Secret is absent");
    Alcotest.(check bool) "no manifest was applied" false (contains "apply" (calls ())))
;;

let%test "local: result fields (svc)" = test_local_result_fields ()
let%test "local: result fields (worker)" = test_local_worker_result ()
let%test "direct: result fields (svc)" = test_direct_result_fields ()
let%test "direct: result fields (worker)" = test_direct_worker_result ()
let%test "gitops: result fields" = test_gitops_result_fields ()
let%test "gitops: file written" = test_gitops_writes_file ()
let%test "gitops: worker file written" = test_gitops_worker ()

let%test "gitops: external secrets preserved (BUG-081)" =
  test_gitops_preserves_external_secrets ()
;;

let%test "gitops: kubernetes-live refused (BUG-081)" =
  test_gitops_rejects_kubernetes_live ()
;;

let%test "gitops: placeholder still emits a Secret (BUG-081)" =
  test_gitops_placeholder_still_emits_secret ()
;;

let%test "apply: fails closed before apply when the workload Secret is absent (BUG-054)" =
  test_apply_fails_closed_when_the_workload_secret_is_absent ()
;;
