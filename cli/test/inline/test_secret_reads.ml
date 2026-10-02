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
for a in "$@"; do
  if [ "$next_is_kind" = 1 ]; then kind="$a"; next_is_kind=0; fi
  case "$a" in
    apply|patch|rollout) [ -z "$verb" ] && verb="$a" ;;
    get) [ -z "$verb" ] && verb="get" && next_is_kind=1 ;;
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
        echo '{"apiVersion":"v1","kind":"Secret","data":{"EXISTING":"ZXhpc3Rpbmc="}}'
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

let set () =
  Sol_cli_secret.set
    ~ctx
    ~workspace:"demo"
    ~namespaces
    ~declared:[]
    ~key:"NEW_KEY"
    ~value:"v"
;;

let is_error = function
  | Error _ -> true
  | Ok _ -> false
;;

let test_set_refuses_an_unreadable_secret () =
  with_fake_kubectl ~mode:"unreachable" (fun ~calls ~manifests:_ ->
    Alcotest.(check bool) "set returns Error" true (is_error (set ()));
    Alcotest.(check bool)
      "nothing is applied over a Secret that could not be read"
      false
      (Sol_cli_string.contains ~needle:"apply" (calls ())))
;;

let test_delete_refuses_an_unreadable_secret () =
  with_fake_kubectl ~mode:"unreachable" (fun ~calls ~manifests:_ ->
    let result =
      Sol_cli_secret.delete ~ctx ~workspace:"demo" ~namespaces ~key:"LEAKED_KEY"
    in
    Alcotest.(check bool) "delete returns Error, not \"deleted\"" true (is_error result);
    Alcotest.(check bool)
      "no patch was sent"
      false
      (Sol_cli_string.contains ~needle:"patch" (calls ())))
;;

let test_list_refuses_an_unreadable_secret () =
  with_fake_kubectl ~mode:"unreachable" (fun ~calls:_ ~manifests:_ ->
    let result = Sol_cli_secret.list ~ctx ~workspace:"demo" ~namespaces in
    Alcotest.(check bool)
      "list returns Error, not an empty key list"
      true
      (is_error result))
;;

let nothing_written calls =
  not
    (Sol_cli_string.contains ~needle:"apply" calls
     || Sol_cli_string.contains ~needle:"patch" calls
     || Sol_cli_string.contains ~needle:"rollout " calls)
;;

let test_later_read_failure_writes_nothing mode () =
  with_fake_kubectl ~mode (fun ~calls ~manifests:_ ->
    Alcotest.(check bool) "set returns Error" true (is_error (set ()));
    Alcotest.(check bool)
      "set wrote and restarted nothing"
      true
      (nothing_written (calls ()));
    let deleted =
      Sol_cli_secret.delete ~ctx ~workspace:"demo" ~namespaces ~key:"EXISTING"
    in
    Alcotest.(check bool) "delete returns Error" true (is_error deleted);
    Alcotest.(check bool)
      "delete patched and restarted nothing"
      true
      (nothing_written (calls ())))
;;

let test_set_creates_a_secret_that_is_absent () =
  with_fake_kubectl ~mode:"missing" (fun ~calls:_ ~manifests ->
    Alcotest.(check bool) "set succeeds on NotFound" false (is_error (set ()));
    Alcotest.(check bool)
      "the new key is applied"
      true
      (Sol_cli_string.contains ~needle:"NEW_KEY" (manifests ())))
;;

let test_set_keeps_the_existing_keys () =
  with_fake_kubectl ~mode:"present" (fun ~calls:_ ~manifests ->
    Alcotest.(check bool) "set succeeds" false (is_error (set ()));
    Alcotest.(check bool)
      "the applied manifest still carries the key it read"
      true
      (Sol_cli_string.contains ~needle:"EXISTING" (manifests ())))
;;

let test_absent_rollout_kind_is_an_empty_listing () =
  with_fake_kubectl ~mode:"no-rollouts" (fun ~calls:_ ~manifests:_ ->
    Alcotest.(check bool)
      "a cluster without the Rollouts CRD still rotates"
      false
      (is_error (set ())))
;;

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
  | Error message -> Alcotest.fail ("expected verification to pass: " ^ message)
;;

let test_verify_names_the_missing_key () =
  match verify ~required_keys:[ "EXISTING"; "MISSING_KEY" ] "present" with
  | Ok () -> Alcotest.fail "a missing key must fail verification"
  | Error message ->
    Alcotest.(check bool)
      "names the workload Secret"
      true
      (Sol_cli_string.contains ~needle:"payments/charge-svc-secrets" message);
    Alcotest.(check bool)
      "names the missing key"
      true
      (Sol_cli_string.contains ~needle:"MISSING_KEY" message);
    Alcotest.(check bool)
      "does not name the key it found"
      false
      (Sol_cli_string.contains ~needle:"EXISTING" message)
;;

let test_verify_rejects_a_blank_value () =
  match verify ~required_keys:[ "BLANK" ] "blank" with
  | Ok () -> Alcotest.fail "an empty secret value must fail verification"
  | Error message ->
    Alcotest.(check bool)
      "names the blank key"
      true
      (Sol_cli_string.contains ~needle:"BLANK" message)
;;

let test_verify_rejects_an_absent_secret () =
  match verify "missing" with
  | Ok () -> Alcotest.fail "an absent Secret must fail verification"
  | Error message ->
    Alcotest.(check bool)
      "names the secret"
      true
      (Sol_cli_string.contains ~needle:"charge-svc-secrets" message)
;;

let test_verify_runtime_secret_reads_the_substrate_secret () =
  match
    with_fake_kubectl ~mode:"present" (fun ~calls:_ ~manifests:_ ->
      Sol_cli_secret.verify_runtime_secret ~ctx ~namespace:"payments")
  with
  | Ok () ->
    Alcotest.fail "the substrate Secret lacks POSTGRES_URL; verification must fail"
  | Error message ->
    Alcotest.(check bool)
      "names the runtime Secret"
      true
      (Sol_cli_string.contains ~needle:"payments/sol-secrets" message);
    Alcotest.(check bool)
      "names the missing contract key"
      true
      (Sol_cli_string.contains ~needle:"POSTGRES_URL" message)
;;

let%test "unreadable is not absent: set" = test_set_refuses_an_unreadable_secret ()
let%test "unreadable is not absent: delete" = test_delete_refuses_an_unreadable_secret ()
let%test "unreadable is not absent: list" = test_list_refuses_an_unreadable_secret ()

let%test "unreadable is not absent: workload Secret listing fails" =
  (test_later_read_failure_writes_nothing "listing-fails") ()
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

let%test "unreadable is not absent: Deployment listing fails" =
  (test_later_read_failure_writes_nothing "workloads-fail") ()
;;

let%test "absent and present still work: absent -> create" =
  test_set_creates_a_secret_that_is_absent ()
;;

let%test "absent and present still work: present -> keys kept" =
  test_set_keeps_the_existing_keys ()
;;

let%test "absent and present still work: no Rollout CRD" =
  test_absent_rollout_kind_is_an_empty_listing ()
;;
