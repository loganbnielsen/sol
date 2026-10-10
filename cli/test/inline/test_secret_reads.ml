let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  with
  | Sys_error _ -> ""
;;

let fake_kubectl ~log ~mode_file =
  Printf.sprintf
    {|#!/bin/sh
verb=""
kind=""
next_is_kind=0
next_is_ns=0
namespace=""
for a in "$@"; do
  if [ "$next_is_kind" = 1 ]; then kind="$a"; next_is_kind=0; fi
  if [ "$next_is_ns" = 1 ]; then namespace="$a"; next_is_ns=0; fi
  case "$a" in
    apply|patch|rollout) [ -z "$verb" ] && verb="$a" ;;
    get) [ -z "$verb" ] && verb="get" && next_is_kind=1 ;;
    -n) next_is_ns=1 ;;
  esac
done
printf '%%s %%s\n' "$verb" "$kind" >> %s
mode=$(cat %s)
if [ "$verb" = "get" ]; then
  if [ "$mode" = "unreachable" ]; then
    echo 'Unable to connect to the server: net/http: TLS handshake timeout' >&2
    exit 1
  fi
  case "$kind" in
    externalsecrets)
      if [ "$mode" = "platform-collision" ] && [ "$namespace" = "notifications" ]; then
        printf 'owner\tsol-secrets\n'
      fi
      exit 0 ;;
    secrets)
      if [ "$mode" = "listing-fails" ]; then
        echo 'Error from server (Forbidden): secrets is forbidden: cannot list resource "secrets"' >&2
        exit 1
      fi
      exit 0 ;;
    deployment)
      if [ "$mode" = "workloads-fail" ]; then
        echo 'Error from server (Forbidden): deployments.apps is forbidden: cannot list resource' >&2
        exit 1
      fi
      exit 0 ;;
    secret)
      if [ "$mode" = "present" ] || [ "$mode" = "listing-fails" ] || [ "$mode" = "workloads-fail" ]; then
        echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"sol-secrets","namespace":"payments","resourceVersion":"1"},"data":{"EXISTING":"ZXhpc3Rpbmc="}}'
        exit 0
      fi
      if [ "$mode" = "runtime-valid" ]; then
        echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"sol-secrets","namespace":"payments","resourceVersion":"1"},"data":{"POSTGRES_URL":"cG9zdGdyZXM6Ly9kYiJ9"}}'
        exit 0
      fi
      if [ "$mode" = "owned-unit" ]; then
        echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"charge-svc-secrets","namespace":"payments","resourceVersion":"1","labels":{"app.kubernetes.io/managed-by":"sol"}},"data":{"EXISTING":"ZXhpc3Rpbmc="}}'
        exit 0
      fi
      if [ "$mode" = "blank" ]; then
        echo '{"apiVersion":"v1","kind":"Secret","data":{"BLANK":""}}'
        exit 0
      fi
      echo 'Error from server (NotFound): secrets "sol-secrets" not found' >&2
      exit 1 ;;
    rollout)
      if [ "$mode" = "no-rollouts" ]; then
        echo 'error: the server doesn'"'"'t have a resource type "rollout"' >&2
        exit 1
      fi
      exit 0 ;;
    *) exit 0 ;;
  esac
fi
if [ "$verb" = "apply" ]; then
  prev=""
  for a in "$@"; do
    if [ "$prev" = "-f" ]; then cat "$a" >> %s.manifests; fi
    prev="$a"
  done
fi
exit 0
|}
    log
    mode_file
    log
;;

let with_fake_kubectl ~mode f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let mode_file = Filename.concat dir "mode" in
  write_file mode_file mode;
  let bin = Filename.concat dir "kubectl" in
  write_file bin (fake_kubectl ~log ~mode_file);
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      List.iter
        (fun f ->
           try Sys.remove f with
           | Sys_error _ -> ())
        [ bin; mode_file; log; log ^ ".manifests" ];
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () ->
       f
         ~calls:(fun () -> read_file log)
         ~manifests:(fun () -> read_file (log ^ ".manifests")))
;;

let ctx = Sol_cli_kube_destination.local_context
let namespaces = [ "payments" ]

let verify ?(secret_name = "charge-svc-secrets") ?(required_keys = [ "EXISTING" ]) mode =
  with_fake_kubectl ~mode (fun ~calls:_ ~manifests:_ ->
    Sol_cli_secret.verify_required_keys
      ~ctx
      ~namespace:"payments"
      ~secret_name
      ~required_keys)
;;

let test_verify_passes_when_required_keys_are_present () =
  match verify "present" with
  | Ok () -> ()
  | Error message -> Windtrap.fail ("expected verification to pass: " ^ message)
;;

let test_verify_names_the_missing_key () =
  match verify ~required_keys:[ "EXISTING"; "MISSING_KEY" ] "present" with
  | Ok () -> Windtrap.fail "a missing key must fail verification"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the workload Secret"
      true
      (Sol_cli_string.contains ~needle:"payments/charge-svc-secrets" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the missing key"
      true
      (Sol_cli_string.contains ~needle:"MISSING_KEY" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"does not name the key it found"
      false
      (Sol_cli_string.contains ~needle:"EXISTING" message)
;;

let test_verify_rejects_a_blank_value () =
  match verify ~required_keys:[ "BLANK" ] "blank" with
  | Ok () -> Windtrap.fail "an empty secret value must fail verification"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the blank key"
      true
      (Sol_cli_string.contains ~needle:"BLANK" message)
;;

let test_verify_rejects_an_absent_secret () =
  match verify "missing" with
  | Ok () -> Windtrap.fail "an absent Secret must fail verification"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the secret"
      true
      (Sol_cli_string.contains ~needle:"charge-svc-secrets" message)
;;

let test_verify_runtime_secret_reads_the_substrate_secret () =
  match
    with_fake_kubectl ~mode:"present" (fun ~calls:_ ~manifests:_ ->
      Sol_cli_secret.verify_runtime_secret ~ctx ~namespace:"payments")
  with
  | Ok () ->
    Windtrap.fail "the substrate Secret lacks POSTGRES_URL; verification must fail"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the runtime Secret"
      true
      (Sol_cli_string.contains ~needle:"payments/sol-secrets" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the missing contract key"
      true
      (Sol_cli_string.contains ~needle:"POSTGRES_URL" message)
;;

let test_platform_set_writes_only_the_runtime_secret () =
  with_fake_kubectl ~mode:"present" (fun ~calls:_ ~manifests ->
    match
      Sol_cli_secret.set_platform_key
        ~ctx
        ~namespaces:[ "payments"; "orders" ]
        ~key:"POSTGRES_URL"
        ~value:"postgres://platform-db"
    with
    | Error message -> Windtrap.failf "platform secret set failed: %s" message
    | Ok _ ->
      let manifests = manifests () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the platform Secret is written"
        true
        (Sol_cli_string.contains ~needle:"name: sol-secrets" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"application Secrets are not written"
        false
        (Sol_cli_string.contains ~needle:"charge-svc-secrets" manifests))
;;

let test_platform_preflight_checks_all_namespaces_before_secret_writes () =
  with_fake_kubectl ~mode:"platform-collision" (fun ~calls:_ ~manifests ->
    match
      Sol_cli_secret.verify_platform_secret_destinations
        ~ctx
        ~namespaces:[ "payments"; "notifications" ]
    with
    | Ok () -> Windtrap.fail "an ExternalSecret collision must fail preflight"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the conflicting shared Secret"
        true
        (Sol_cli_string.contains
           ~needle:"ExternalSecret already targets this object"
           message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"preflight writes no shared Secret before discovering the collision"
        false
        (Sol_cli_string.contains ~needle:"kind: Secret" (manifests ())))
;;

let test_unit_set_writes_only_its_unit_secret () =
  with_fake_kubectl ~mode:"owned-unit" (fun ~calls:_ ~manifests ->
    match
      Sol_cli_secret.set_unit_key
        ~ctx
        ~namespace:"payments"
        ~secret_name:"charge-svc-secrets"
        ~key:"API_TOKEN"
        ~value:"unit-only"
    with
    | Error message -> Windtrap.failf "unit secret set failed: %s" message
    | Ok _ ->
      let manifests = manifests () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the selected unit Secret is written"
        true
        (Sol_cli_string.contains ~needle:"name: charge-svc-secrets" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the platform Secret is not written"
        false
        (Sol_cli_string.contains ~needle:"name: sol-secrets" manifests))
;;

let test_platform_readiness_requires_only_the_database_job_input () =
  match
    with_fake_kubectl ~mode:"runtime-valid" (fun ~calls:_ ~manifests:_ ->
      Sol_cli_secret.verify_runtime_secret ~ctx ~namespace:"payments")
  with
  | Ok () -> ()
  | Error message -> Windtrap.failf "valid platform Job input was rejected: %s" message
;;

let test_contract_readiness_names_missing_tls_job_input () =
  match
    with_fake_kubectl ~mode:"runtime-valid" (fun ~calls:_ ~manifests:_ ->
      Sol_cli_secret.verify_runtime_secret_keys
        ~ctx
        ~namespace:"payments"
        ~required_keys:[ "KAFKA_SASL_PASSWORD"; "KAFKA_SSL_CA_CERT" ])
  with
  | Ok () ->
    Windtrap.fail "a runtime Secret without Kafka inputs passed contract readiness"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names both missing TLS inputs"
      true
      (Sol_cli_string.contains ~needle:"KAFKA_SASL_PASSWORD" message
       && Sol_cli_string.contains ~needle:"KAFKA_SSL_CA_CERT" message)
;;

let test_tls_contract_job_refuses_before_submission_without_platform_inputs () =
  with_fake_kubectl ~mode:"missing" (fun ~calls ~manifests:_ ->
    match
      Sol_cli_contract.reconcile_in_destination
        ~ctx
        ~platform_shape:Sol_cli_profile.Durable
        ~namespace:"payments"
        ~image:"contract-image"
    with
    | Ok () -> Windtrap.fail "TLS contract Job started without platform Kafka inputs"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the required Kafka platform values"
        true
        (Sol_cli_string.contains ~needle:"KAFKA_SASL_PASSWORD" message
         && Sol_cli_string.contains ~needle:"KAFKA_SSL_CA_CERT" message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"does not submit a Job before the values are verified"
        false
        (Sol_cli_string.contains ~needle:"apply" (calls ())))
;;

let%test "verify: present required keys pass" =
  test_verify_passes_when_required_keys_are_present ()
;;

let%test "verify: a missing key fails and is named" = test_verify_names_the_missing_key ()
let%test "verify: a blank value fails" = test_verify_rejects_a_blank_value ()
let%test "verify: an absent Secret fails" = test_verify_rejects_an_absent_secret ()

let%test "verify: runtime Secret check reads the substrate Secret" =
  test_verify_runtime_secret_reads_the_substrate_secret ()
;;

let%test "scope: platform writes only the shared Job Secret" =
  test_platform_set_writes_only_the_runtime_secret ()
;;

let%test "scope: platform secret destinations preflight as a target" =
  test_platform_preflight_checks_all_namespaces_before_secret_writes ()
;;

let%test "scope: unit writes only the selected unit Secret" =
  test_unit_set_writes_only_its_unit_secret ()
;;

let%test "verify: platform readiness checks the database Job input" =
  test_platform_readiness_requires_only_the_database_job_input ()
;;

let%test "verify: TLS contract readiness checks both Kafka Job inputs" =
  test_contract_readiness_names_missing_tls_job_input ()
;;

let%test "verify: TLS contract Job requires platform inputs before submit" =
  test_tls_contract_job_refuses_before_submission_without_platform_inputs ()
;;
