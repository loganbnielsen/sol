(* Sol_cli_deployment_state: the consumer-group record and the removal guard.

   Runs against a fake kubectl on PATH (never a real cluster), which answers per a
   mode file and logs every verb, so a test cannot touch whatever cluster the
   developer's kubeconfig points at.

   BUG-045 / FND-0038: an unreadable record used to read as "no previous groups",
   so the guard passed silently when the cluster could not be asked, and a failed
   write was only a warning. *)

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try In_channel.with_open_text path In_channel.input_all with
  | Sys_error _ -> ""
;;

(* Modes: present (groups "a\nb"), missing (NotFound), forbidden (get fails),
   apply-fails (get ok, apply refused). *)
let fake_kubectl ~log ~mode_file =
  Printf.sprintf
    {|#!/bin/sh
verb=""
for a in "$@"; do
  case "$a" in apply|get) verb="$a"; break ;; esac
done
echo "$verb" >> %s
mode=$(cat %s)
if [ "$verb" = "get" ]; then
  case "$mode" in
    missing) echo 'Error from server (NotFound): configmaps "sol-deploy-state-ws" not found' >&2; exit 1 ;;
    forbidden) echo 'Error from server (Forbidden): configmaps "sol-deploy-state-ws" is forbidden' >&2; exit 1 ;;
    *) printf 'a\nb'; exit 0 ;;
  esac
fi
if [ "$verb" = "apply" ] && [ "$mode" = "apply-fails" ]; then
  echo 'Error from server (Forbidden): cannot patch configmaps' >&2; exit 1
fi
exit 0
|}
    log
    mode_file
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
        [ bin; mode_file; log ];
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

(* ── record_outcome ──────────────────────────────────────────────────────── *)

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

(* ── load_deployed_groups ────────────────────────────────────────────────── *)

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

(* ── check_removed_groups (the guard) ───────────────────────────────────── *)

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

(* ── pure helpers ────────────────────────────────────────────────────────── *)

let test_removed_consumer_groups () =
  let removed prev next = Sol_cli_deployment_state.removed_consumer_groups ~prev ~next in
  Alcotest.(check (list string))
    "removal"
    [ "c" ]
    (removed [ "a"; "b"; "c" ] [ "a"; "b" ]);
  Alcotest.(check (list string)) "stable" [] (removed [ "a" ] [ "a" ]);
  Alcotest.(check (list string)) "additions ignored" [] (removed [ "a" ] [ "a"; "b" ])
;;

(* BUG-025: the state ConfigMap name must be a valid object name. *)
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

let () =
  Alcotest.run
    "deployment_state"
    [ ( "record_outcome"
      , [ Alcotest.test_case
            "non-applied outcomes touch nothing"
            `Quick
            test_non_applied_outcomes_touch_nothing
        ; Alcotest.test_case
            "applied writes the record"
            `Quick
            test_applied_writes_the_record
        ; Alcotest.test_case
            "failed write is an error"
            `Quick
            test_failed_write_is_an_error
        ] )
    ; ( "load_deployed_groups"
      , [ Alcotest.test_case "present" `Quick test_load_present
        ; Alcotest.test_case
            "missing = first deploy"
            `Quick
            test_load_missing_is_a_first_deploy
        ; Alcotest.test_case
            "unreadable is an error"
            `Quick
            test_load_unreadable_is_an_error
        ] )
    ; ( "check_removed_groups"
      , [ Alcotest.test_case
            "refuses on unreadable record"
            `Quick
            test_guard_refuses_on_unreadable_record
        ; Alcotest.test_case
            "confirm proceeds on unreadable record"
            `Quick
            test_guard_confirm_proceeds_on_unreadable_record
        ; Alcotest.test_case
            "refuses removal, names the real hazard"
            `Quick
            test_guard_refuses_removal_and_names_the_real_hazard
        ; Alcotest.test_case
            "passes when stable or first"
            `Quick
            test_guard_passes_when_stable_or_first
        ] )
    ; ( "helpers"
      , [ Alcotest.test_case "removed_consumer_groups" `Quick test_removed_consumer_groups
        ; Alcotest.test_case
            "configmap name"
            `Quick
            test_configmap_name_sanitizes_workspace
        ] )
    ]
;;
