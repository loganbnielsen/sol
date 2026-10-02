let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try In_channel.with_open_text path In_channel.input_all with
  | Sys_error _ -> ""
;;

let fake_kubectl ~log ~mode_file ~state_file =
  Printf.sprintf
    {|#!/bin/sh
verb=""
file=""
previous=""
for a in "$@"; do
  case "$a" in apply|get) verb="$a" ;; esac
  if [ "$previous" = "-f" ]; then file="$a"; fi
  previous="$a"
done
echo "$verb" >> %s
mode=$(cat %s)
if [ "$verb" = "apply" ]; then
  if [ "$mode" = "apply-fails" ]; then
    echo 'Error from server (Forbidden): cannot patch configmaps' >&2; exit 1
  fi
  if [ -n "$file" ]; then
    sed -n 's/.*"consumer_groups":"\([^"]*\)".*/\1/p' "$file" > %s
  fi
  exit 0
fi
if [ "$verb" = "get" ]; then
  case "$mode" in
    missing) echo 'Error from server (NotFound): configmaps "sol-deploy-state-ws" not found' >&2; exit 1 ;;
    forbidden) echo 'Error from server (Forbidden): configmaps "sol-deploy-state-ws" is forbidden' >&2; exit 1 ;;
    recorded) if [ -f %s ]; then cat %s; else exit 0; fi ;;
    *) printf 'a\nb'; exit 0 ;;
  esac
fi
exit 0
|}
    log
    mode_file
    state_file
    state_file
    state_file
;;

let with_fake_kubectl ~mode f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let mode_file = Filename.concat dir "mode" in
  let state_file = Filename.concat dir "recorded" in
  write_file mode_file mode;
  let bin = Filename.concat dir "kubectl" in
  write_file bin (fake_kubectl ~log ~mode_file ~state_file);
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
        [ bin; mode_file; log; state_file ];
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () -> f ~calls:(fun () -> read_file log))
;;

let ctx = Sol_cli_kube_destination.local_context

let applied =
  Sol_cli_deployment_state.Applied
    { namespace = "default"
    ; name = "svc"
    ; image = "registry/svc:abc123"
    ; consumer_groups = [ "payments.events"; "comms.notifications" ]
    }
;;

let test_non_applied_outcomes_touch_nothing () =
  with_fake_kubectl ~mode:"present" (fun ~calls ->
    List.iter
      (fun outcome ->
         Alcotest.(check bool)
           "Ok"
           true
           (Result.is_ok (Sol_cli_deployment_state.record_outcome ~ctx "ws" outcome)))
      [ Sol_cli_deployment_state.Dry_run
      ; Sol_cli_deployment_state.Failed { phase = "build"; message = "boom" }
      ; Sol_cli_deployment_state.Emitted { file = "/tmp/x.yaml" }
      ];
    Alcotest.(check string) "no kubectl call" "" (calls ()))
;;

let test_applied_writes_the_record () =
  with_fake_kubectl ~mode:"present" (fun ~calls ->
    Alcotest.(check bool)
      "Ok"
      true
      (Result.is_ok (Sol_cli_deployment_state.record_outcome ~ctx "ws" applied));
    Alcotest.(check bool)
      "applied"
      true
      (Sol_cli_string.contains ~needle:"apply" (calls ())))
;;

let test_failed_write_is_an_error () =
  with_fake_kubectl ~mode:"apply-fails" (fun ~calls:_ ->
    match Sol_cli_deployment_state.record_outcome ~ctx "ws" applied with
    | Ok () -> Alcotest.fail "a record the next deploy cannot read must not be Ok"
    | Error msg ->
      Alcotest.(check bool)
        "names the configmap"
        true
        (Sol_cli_string.contains ~needle:"sol-deploy-state" msg))
;;

let test_load_present () =
  with_fake_kubectl ~mode:"present" (fun ~calls:_ ->
    Alcotest.(check (result (list string) string))
      "recorded groups"
      (Ok [ "a"; "b" ])
      (Sol_cli_deployment_state.load_deployed_groups ~ctx "ws"))
;;

let test_load_missing_is_a_first_deploy () =
  with_fake_kubectl ~mode:"missing" (fun ~calls:_ ->
    Alcotest.(check (result (list string) string))
      "no record yet"
      (Ok [])
      (Sol_cli_deployment_state.load_deployed_groups ~ctx "ws"))
;;

let test_load_unreadable_is_an_error () =
  with_fake_kubectl ~mode:"forbidden" (fun ~calls:_ ->
    Alcotest.(check bool)
      "Error, not an empty list"
      true
      (Result.is_error (Sol_cli_deployment_state.load_deployed_groups ~ctx "ws")))
;;

let check ~mode ~confirm next =
  with_fake_kubectl ~mode (fun ~calls:_ ->
    Sol_cli_deployment_state.check_removed_groups
      ~ctx
      ~workspace:"ws"
      ~confirm_group_change:confirm
      ~next)
;;

let test_guard_refuses_on_unreadable_record () =
  Alcotest.(check bool)
    "unreadable record refuses"
    true
    (Result.is_error (check ~mode:"forbidden" ~confirm:false [ "a"; "b" ]))
;;

let test_guard_confirm_proceeds_on_unreadable_record () =
  Alcotest.(check bool)
    "--confirm-group-change proceeds"
    true
    (Result.is_ok (check ~mode:"forbidden" ~confirm:true [ "a" ]))
;;

let test_guard_refuses_removal_and_names_the_real_hazard () =
  match check ~mode:"present" ~confirm:false [ "a" ] with
  | Ok () -> Alcotest.fail "removing group b must be refused"
  | Error msg ->
    Alcotest.(check bool)
      "names the removed group"
      true
      (Sol_cli_string.contains ~needle:"  - b" msg);
    Alcotest.(check bool)
      "describes reprocessing from the earliest offset, not skipping"
      true
      (Sol_cli_string.contains ~needle:"EARLIEST" msg)
;;

let test_guard_passes_when_stable_or_first () =
  Alcotest.(check bool)
    "stable"
    true
    (Result.is_ok (check ~mode:"present" ~confirm:false [ "a"; "b"; "c" ]));
  Alcotest.(check bool)
    "first deploy"
    true
    (Result.is_ok (check ~mode:"missing" ~confirm:false [ "a" ]))
;;

let test_removed_consumer_groups () =
  let removed prev next = Sol_cli_deployment_state.removed_consumer_groups ~prev ~next in
  Alcotest.(check (list string))
    "removal"
    [ "c" ]
    (removed [ "a"; "b"; "c" ] [ "a"; "b" ]);
  Alcotest.(check (list string)) "stable" [] (removed [ "a" ] [ "a" ]);
  Alcotest.(check (list string)) "additions ignored" [] (removed [ "a" ] [ "a"; "b" ])
;;

let test_configmap_name_sanitizes_workspace () =
  Alcotest.(check string)
    "underscore workspace"
    "sol-deploy-state-ci-smoke"
    (Sol_cli_deployment_state.deploy_state_configmap_name "ci_smoke");
  Alcotest.(check string)
    "uppercase and underscore workspace"
    "sol-deploy-state-my-app"
    (Sol_cli_deployment_state.deploy_state_configmap_name "My_App")
;;

let test_a_corrected_record_is_what_the_next_check_reads () =
  with_fake_kubectl ~mode:"recorded" (fun ~calls:_ ->
    Alcotest.(check bool)
      "the rollback records the restored release's groups (BUG-090)"
      true
      (Result.is_ok
         (Sol_cli_deployment_state.record_consumer_groups
            ~ctx
            ~workspace:"ws"
            [ "myapp.comms.notify_worker" ]));
    Alcotest.(check bool)
      "a plan that still holds that worker's group is not a removal"
      true
      (Result.is_ok
         (Sol_cli_deployment_state.check_removed_groups
            ~ctx
            ~workspace:"ws"
            ~confirm_group_change:false
            ~next:[ "myapp.comms.notify_worker" ]));
    match
      Sol_cli_deployment_state.check_removed_groups
        ~ctx
        ~workspace:"ws"
        ~confirm_group_change:false
        ~next:[]
    with
    | Ok () -> Alcotest.fail "a plan without the restored worker must be refused"
    | Error msg ->
      Alcotest.(check bool)
        "and a real removal is reported against the corrected record"
        true
        (Sol_cli_string.contains ~needle:"myapp.comms.notify_worker" msg))
;;

let%test "record_outcome: non-applied outcomes touch nothing" =
  test_non_applied_outcomes_touch_nothing ()
;;

let%test "record_outcome: applied writes the record" = test_applied_writes_the_record ()
let%test "record_outcome: failed write is an error" = test_failed_write_is_an_error ()

let%test "record_outcome: a corrected record is what the next check reads (BUG-090)" =
  test_a_corrected_record_is_what_the_next_check_reads ()
;;

let%test "load_deployed_groups: present" = test_load_present ()

let%test "load_deployed_groups: missing = first deploy" =
  test_load_missing_is_a_first_deploy ()
;;

let%test "load_deployed_groups: unreadable is an error" =
  test_load_unreadable_is_an_error ()
;;

let%test "check_removed_groups: refuses on unreadable record" =
  test_guard_refuses_on_unreadable_record ()
;;

let%test "check_removed_groups: confirm proceeds on unreadable record" =
  test_guard_confirm_proceeds_on_unreadable_record ()
;;

let%test "check_removed_groups: refuses removal, names the real hazard" =
  test_guard_refuses_removal_and_names_the_real_hazard ()
;;

let%test "check_removed_groups: passes when stable or first" =
  test_guard_passes_when_stable_or_first ()
;;

let%test "helpers: removed_consumer_groups" = test_removed_consumer_groups ()
let%test "helpers: configmap name" = test_configmap_name_sanitizes_workspace ()
