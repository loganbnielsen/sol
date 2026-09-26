(* BUG-040 / FND-0031: a Secret Sol could not read is not a Secret that is absent.

   [sol secret set] writes what it read back into the Secret, so reading "could not
   ask" as "nothing there" made it apply a manifest without the existing keys (which
   client-side apply then removes) and report success; [delete] reported a deletion
   it never sent; [list] reported no keys. The fake kubectl answers every [get] per a
   mode file and records each verb plus every manifest it was asked to apply, so the
   assertions are about what Sol invoked, not about what the code appears to say. *)

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

(* Modes:
   - unreachable: every get fails like an API server that cannot be reached;
   - missing:     the Secret is NotFound, listings succeed and are empty;
   - present:     the Secret exists with key EXISTING, listings are empty;
   - no-rollouts: as [missing], but the Rollout kind is not served (CRD absent);
   - listing-fails:   [sol-secrets] is readable, the per-workload Secret listing is Forbidden;
   - workloads-fail:  Secrets are readable, the Deployment listing is Forbidden.
   The last two get past the first read, so they prove every read happens before the
   first write: a failure there must leave nothing applied, patched or restarted. *)
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
    ~env:"cloud"
    ~workspace:"demo"
    ~namespaces
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
      Sol_cli_secret.delete
        ~ctx
        ~env:"cloud"
        ~workspace:"demo"
        ~namespaces
        ~key:"LEAKED_KEY"
    in
    Alcotest.(check bool) "delete returns Error, not \"deleted\"" true (is_error result);
    Alcotest.(check bool)
      "no patch was sent"
      false
      (Sol_cli_string.contains ~needle:"patch" (calls ())))
;;

let test_list_refuses_an_unreadable_secret () =
  with_fake_kubectl ~mode:"unreachable" (fun ~calls:_ ~manifests:_ ->
    let result = Sol_cli_secret.list ~ctx ~env:"cloud" ~workspace:"demo" ~namespaces in
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
      Sol_cli_secret.delete
        ~ctx
        ~env:"cloud"
        ~workspace:"demo"
        ~namespaces
        ~key:"EXISTING"
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

let () =
  Alcotest.run
    "secret_reads"
    [ ( "unreadable is not absent"
      , [ Alcotest.test_case "set" `Quick test_set_refuses_an_unreadable_secret
        ; Alcotest.test_case "delete" `Quick test_delete_refuses_an_unreadable_secret
        ; Alcotest.test_case "list" `Quick test_list_refuses_an_unreadable_secret
        ; Alcotest.test_case
            "workload Secret listing fails"
            `Quick
            (test_later_read_failure_writes_nothing "listing-fails")
        ; Alcotest.test_case
            "Deployment listing fails"
            `Quick
            (test_later_read_failure_writes_nothing "workloads-fail")
        ] )
    ; ( "absent and present still work"
      , [ Alcotest.test_case
            "absent -> create"
            `Quick
            test_set_creates_a_secret_that_is_absent
        ; Alcotest.test_case
            "present -> keys kept"
            `Quick
            test_set_keeps_the_existing_keys
        ; Alcotest.test_case
            "no Rollout CRD"
            `Quick
            test_absent_rollout_kind_is_an_empty_listing
        ] )
    ]
;;
