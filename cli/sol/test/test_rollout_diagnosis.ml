let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

module D = Sol_cli_rollout_diagnosis

let healthy_pod_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-abc"},
   "status": {"phase": "Running",
     "containerStatuses": [
       {"ready": true, "restartCount": 0, "image": "registry/charge-svc:sha1",
        "state": {"running": {"startedAt": "2026-09-01T00:00:00Z"}}}
     ]}}
]}
|}
;;

let succeeded_pod_json =
  {|
{"items": [
  {"metadata": {"name": "invoice-fn-abc"},
   "status": {"phase": "Succeeded",
     "containerStatuses": [
       {"ready": false, "restartCount": 0, "image": "registry/invoice-fn:sha1",
        "state": {"terminated": {"reason": "Completed", "exitCode": 0}}}
     ]}}
]}
|}
;;

let image_pull_backoff_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-xyz"},
   "status": {"phase": "Pending",
     "containerStatuses": [
       {"ready": false, "restartCount": 0, "image": "registry/charge-svc:bad-tag",
        "state": {"waiting": {"reason": "ImagePullBackOff",
                               "message": "Back-off pulling image \"registry/charge-svc:bad-tag\""}}}
     ]}}
]}
|}
;;

let crash_loop_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-crash"},
   "status": {"phase": "Running",
     "containerStatuses": [
       {"ready": false, "restartCount": 6, "image": "registry/charge-svc:sha2",
        "state": {"waiting": {"reason": "CrashLoopBackOff", "message": null}},
        "lastState": {"terminated": {"reason": "OOMKilled", "exitCode": 137}}}
     ]}}
]}
|}
;;

let pending_no_containers_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-pending"},
   "status": {"phase": "Pending"}}
]}
|}
;;

let container_creating_json =
  {|
{"items": [
  {"metadata": {"name": "invoice-fn-starting"},
   "status": {"phase": "Pending",
     "containerStatuses": [
       {"ready": false, "restartCount": 0, "image": "registry/invoice-fn:sha1",
        "state": {"waiting": {"reason": "ContainerCreating", "message": null}}}
     ]}}
]}
|}
;;

let container_creating_after_restart_json =
  {|
{"items": [
  {"metadata": {"name": "invoice-fn-retrying"},
   "status": {"phase": "Pending",
     "containerStatuses": [
       {"ready": false, "restartCount": 1, "image": "registry/invoice-fn:sha1",
        "state": {"waiting": {"reason": "ContainerCreating", "message": null}}}
     ]}}
]}
|}
;;

let missing_status_pod_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-missing-status"}},
  {"metadata": {"name": "charge-svc-abc"},
   "status": {"phase": "Running",
     "containerStatuses": [
       {"ready": true, "restartCount": 0, "image": "registry/charge-svc:sha1",
        "state": {"running": {"startedAt": "2026-09-01T00:00:00Z"}}}
     ]}}
]}
|}
;;

let events_json =
  {|
{"items": [
  {"type": "Warning", "reason": "FailedPull", "message": "rpc error: pull access denied",
   "count": 3, "lastTimestamp": "2026-09-01T00:00:01Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-xyz"}},
  {"type": "Warning", "reason": "BackOff", "message": "Back-off pulling image",
   "count": 5, "lastTimestamp": "2026-09-01T00:00:05Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-xyz"}},
  {"type": "Warning", "reason": "FailedScheduling", "message": "0/2 nodes available",
   "count": 1, "lastTimestamp": "2026-09-01T00:00:00Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-pending"}},
  {"type": "Normal", "reason": "Scheduled", "message": "unrelated pod",
   "count": 1, "lastTimestamp": "2026-09-01T00:00:00Z",
   "involvedObject": {"kind": "Pod", "name": "other-svc-abc"}}
]}
|}
;;

(* ── parse_pods_json ─────────────────────────────────────────────────── *)

let test_parse_healthy_pod () =
  match D.parse_pods_json healthy_pod_json with
  | [ p ] ->
    check_string "name" "charge-svc-abc" p.name;
    check_string "phase" "Running" p.phase;
    check_bool "ready" true p.ready;
    check_int "restarts" 0 p.restarts;
    check_bool "is_healthy" true (D.is_healthy p)
  | _ -> Alcotest.fail "expected exactly one pod"
;;

let test_parse_image_pull_backoff () =
  match D.parse_pods_json image_pull_backoff_json with
  | [ p ] ->
    check_bool "is_healthy" false (D.is_healthy p);
    (match p.state with
     | D.Waiting { reason; _ } -> check_string "reason" "ImagePullBackOff" reason
     | _ -> Alcotest.fail "expected Waiting state")
  | _ -> Alcotest.fail "expected exactly one pod"
;;

let test_parse_crash_loop_last_termination () =
  match D.parse_pods_json crash_loop_json with
  | [ p ] ->
    check_int "restarts" 6 p.restarts;
    check_string
      "last_terminated_reason"
      "OOMKilled"
      (Option.value ~default:"none" p.last_terminated_reason)
  | _ -> Alcotest.fail "expected exactly one pod"
;;

let test_parse_pod_with_no_container_statuses () =
  match D.parse_pods_json pending_no_containers_json with
  | [ p ] ->
    check_string "phase" "Pending" p.phase;
    check_bool "is_healthy" false (D.is_healthy p)
  | _ -> Alcotest.fail "expected exactly one pod"
;;

let test_parse_pod_with_missing_status_keeps_list () =
  match D.parse_pods_json missing_status_pod_json with
  | [ missing; healthy ] ->
    check_string "missing name" "charge-svc-missing-status" missing.name;
    check_string "missing phase" "Unknown" missing.phase;
    check_bool "missing is unhealthy" false (D.is_healthy missing);
    check_string "healthy name" "charge-svc-abc" healthy.name;
    check_bool "healthy still parsed" true (D.is_healthy healthy)
  | pods -> Alcotest.failf "expected two pods, got %d" (List.length pods)
;;

(* ── parse_events_json / events_for_pod ─────────────────────────────── *)

let test_events_for_pod_filters_and_orders () =
  let events = D.parse_events_json events_json in
  let for_xyz = D.events_for_pod ~pod_name:"charge-svc-xyz" events in
  check_int "two events for charge-svc-xyz" 2 (List.length for_xyz);
  check_string "most recent first" "BackOff" (List.hd for_xyz).D.reason
;;

let test_events_for_pod_excludes_other_pods () =
  let events = D.parse_events_json events_json in
  let for_other = D.events_for_pod ~pod_name:"charge-svc-abc" events in
  check_int "no events for unrelated pod" 0 (List.length for_other)
;;

(* ── format_service_diagnosis ───────────────────────────────────────── *)

let test_format_service_diagnosis_none_when_healthy () =
  let pods = D.parse_pods_json healthy_pod_json in
  check_bool
    "no diagnosis for healthy service"
    true
    (Option.is_none
       (D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events [])))
;;

let test_format_service_diagnosis_includes_events_and_reason () =
  let pods = D.parse_pods_json image_pull_backoff_json in
  let events = D.parse_events_json events_json in
  match D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events events) with
  | None -> Alcotest.fail "expected a diagnosis"
  | Some diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (try
         ignore
           (Str.search_forward
              (Str.regexp_string "charge-svc rollout failed")
              diagnosis
              0);
         true
       with
       | Not_found -> false);
    check_bool
      "mentions ImagePullBackOff"
      true
      (try
         ignore (Str.search_forward (Str.regexp_string "ImagePullBackOff") diagnosis 0);
         true
       with
       | Not_found -> false);
    check_bool
      "mentions FailedPull event"
      true
      (try
         ignore (Str.search_forward (Str.regexp_string "FailedPull") diagnosis 0);
         true
       with
       | Not_found -> false)
;;

let test_format_service_diagnosis_reports_empty_pod_list () =
  (* Empty here means kubectl confirmed zero pods, not a fetch failure. *)
  match D.format_service_diagnosis ~service_name:"charge-svc" [] (D.Events []) with
  | None -> Alcotest.fail "expected a diagnosis for zero pods, got None (looks healthy)"
  | Some diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (try
         ignore
           (Str.search_forward
              (Str.regexp_string "charge-svc rollout failed")
              diagnosis
              0);
         true
       with
       | Not_found -> false);
    check_bool
      "mentions no pods found"
      true
      (try
         ignore (Str.search_forward (Str.regexp_string "No pods found") diagnosis 0);
         true
       with
       | Not_found -> false)
;;

let test_format_service_diagnosis_succeeded_pod_still_flagged_when_continuous () =
  let pods = D.parse_pods_json succeeded_pod_json in
  check_bool
    "a Succeeded pod is still a finding for Continuous (Svc/Worker)"
    true
    (Option.is_some
       (D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events [])))
;;

(* ── format_cronjob_diagnosis (Ephemeral/Fn) ────────────────────────────── *)

let never_scheduled : D.cronjob_status =
  { last_schedule_time = None
  ; last_successful_time = None
  ; active_count = 0
  ; active_job_names = []
  }
;;

let idle_last_run_succeeded : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-02T10:00:05Z"
  ; active_count = 0
  ; active_job_names = []
  }
;;

let idle_last_run_failed : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-01T10:00:05Z" (* stale, from an earlier run *)
  ; active_count = 0
  ; active_job_names = []
  }
;;

let idle_success_at_schedule_boundary : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-02T10:00:00Z"
  ; active_count = 0
  ; active_job_names = []
  }
;;

let idle_never_succeeded : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = None
  ; active_count = 0
  ; active_job_names = []
  }
;;

let run_currently_active : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = None
  ; active_count = 1
  ; active_job_names = [ "invoice-fn-29384710-abcde" ]
  }
;;

let test_format_cronjob_diagnosis_never_scheduled_is_ok () =
  check_bool
    "never scheduled -> no diagnosis"
    true
    (Option.is_none
       (D.format_cronjob_diagnosis ~service_name:"invoice-fn" (D.Found never_scheduled)))
;;

let test_format_cronjob_diagnosis_last_run_succeeded_is_ok () =
  check_bool
    "most recent run succeeded -> no diagnosis"
    true
    (Option.is_none
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_last_run_succeeded)))
;;

let test_format_cronjob_diagnosis_success_at_schedule_boundary_is_ok () =
  check_bool
    "success at the same instant as the schedule trigger -> no diagnosis"
    true
    (Option.is_none
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_success_at_schedule_boundary)))
;;

let test_format_cronjob_diagnosis_last_run_failed_is_flagged () =
  match
    D.format_cronjob_diagnosis ~service_name:"invoice-fn" (D.Found idle_last_run_failed)
  with
  | None ->
    Alcotest.fail
      "expected a diagnosis for a most-recent-run failure, got None (looks healthy)"
  | Some diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (try
         ignore
           (Str.search_forward
              (Str.regexp_string "invoice-fn rollout failed")
              diagnosis
              0);
         true
       with
       | Not_found -> false);
    check_bool
      "mentions the schedule time"
      true
      (try
         ignore
           (Str.search_forward (Str.regexp_string "2026-09-02T10:00:00Z") diagnosis 0);
         true
       with
       | Not_found -> false)
;;

let test_format_cronjob_diagnosis_never_succeeded_is_flagged () =
  check_bool
    "scheduled but never once succeeded -> flagged"
    true
    (Option.is_some
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_never_succeeded)))
;;

let test_format_cronjob_diagnosis_active_run_is_ok () =
  (* Active-run pod failures are bounded by the CronJob backoff/failure state. *)
  check_bool
    "a currently-active run is not (yet) a diagnosis"
    true
    (Option.is_none
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found run_currently_active)))
;;

let test_format_cronjob_diagnosis_missing_is_flagged () =
  match D.format_cronjob_diagnosis ~service_name:"invoice-fn" D.Missing with
  | None ->
    Alcotest.fail "expected a diagnosis for a missing CronJob, got None (looks healthy)"
  | Some diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (try
         ignore
           (Str.search_forward
              (Str.regexp_string "invoice-fn rollout failed")
              diagnosis
              0);
         true
       with
       | Not_found -> false);
    check_bool
      "mentions not found"
      true
      (try
         ignore (Str.search_forward (Str.regexp_string "not found") diagnosis 0);
         true
       with
       | Not_found -> false)
;;

let test_format_cronjob_diagnosis_unavailable_stays_silent () =
  check_bool
    "an unavailable (transient failure) fetch is not a diagnosis"
    true
    (Option.is_none (D.format_cronjob_diagnosis ~service_name:"invoice-fn" D.Unavailable))
;;

(* ── format_active_run_diagnosis (Ephemeral/Fn active run) ──────────────── *)

let test_format_active_run_diagnosis_running_pod_is_ok () =
  let pods = D.parse_pods_json healthy_pod_json in
  check_bool
    "a Running, ready pod is not a finding"
    true
    (Option.is_none
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

(* Unlike a Continuous pod, Succeeded is expected here: an active run
   finishing is not a failure. *)
let test_format_active_run_diagnosis_succeeded_pod_is_ok () =
  let pods = D.parse_pods_json succeeded_pod_json in
  check_bool
    "a Succeeded active-run pod is not a finding"
    true
    (Option.is_none
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_stuck_pod_is_flagged () =
  let pods = D.parse_pods_json image_pull_backoff_json in
  check_bool
    "a stuck (ImagePullBackOff) active-run pod is a finding"
    true
    (Option.is_some
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

(* Every invocation passes through this state en route to Running; it must
   not be a finding or every startup would false-positive. *)
let test_format_active_run_diagnosis_pending_startup_is_ok () =
  let pods = D.parse_pods_json pending_no_containers_json in
  check_bool
    "a freshly-scheduled pod with no container status yet is not a finding"
    true
    (Option.is_none
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

(* Otherwise indistinguishable from normal startup -- FailedScheduling is
   the signal that it's actually stuck. *)
let test_format_active_run_diagnosis_failed_scheduling_is_flagged () =
  let pods = D.parse_pods_json pending_no_containers_json in
  let events = D.parse_events_json events_json in
  check_bool
    "a FailedScheduling pod is still a finding despite looking like normal startup"
    true
    (Option.is_some
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events events)))
;;

let test_format_active_run_diagnosis_container_creating_is_ok () =
  let pods = D.parse_pods_json container_creating_json in
  check_bool
    "ContainerCreating with no restarts is not a finding"
    true
    (Option.is_none
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

(* Leniency covers zero restarts only -- after a restart, the same state
   could be a crash-loop retry. *)
let test_format_active_run_diagnosis_container_creating_after_restart_is_flagged () =
  let pods = D.parse_pods_json container_creating_after_restart_json in
  check_bool
    "ContainerCreating after a restart is still a finding"
    true
    (Option.is_some
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_parse_cronjob_status () =
  let json =
    {|{"status": {"lastScheduleTime": "2026-09-02T10:00:00Z", "lastSuccessfulTime": "2026-09-02T10:00:05Z", "active": [{"name": "invoice-fn-1"}]}}|}
  in
  match D.parse_cronjob_status json with
  | None -> Alcotest.fail "expected Some cronjob_status"
  | Some (status : D.cronjob_status) ->
    check_string
      "lastScheduleTime"
      "2026-09-02T10:00:00Z"
      (Option.value ~default:"" status.last_schedule_time);
    check_string
      "lastSuccessfulTime"
      "2026-09-02T10:00:05Z"
      (Option.value ~default:"" status.last_successful_time);
    check_int "active_count" 1 status.active_count;
    check_string
      "active_job_names"
      "invoice-fn-1"
      (match status.active_job_names with
       | [ name ] -> name
       | _ -> "")
;;

let test_parse_cronjob_status_never_scheduled () =
  match D.parse_cronjob_status {|{"status": {}}|} with
  | None -> Alcotest.fail "expected Some cronjob_status"
  | Some (status : D.cronjob_status) ->
    check_bool "no lastScheduleTime" true (status.last_schedule_time = None);
    check_int "active_count defaults to 0" 0 status.active_count
;;

(* Yojson.Safe.Util.member returns `Null for an absent key rather than
   raising, but member on `Null itself raises -- a CronJob JSON with no
   "status" key at all (not even an empty object) must still parse to
   Some with the "never happened" defaults, not fall through the raise
   into None (Unavailable). *)
let test_parse_cronjob_status_status_key_absent () =
  match D.parse_cronjob_status {|{}|} with
  | None -> Alcotest.fail "expected Some cronjob_status, got None (Unavailable)"
  | Some (status : D.cronjob_status) ->
    check_bool "no lastScheduleTime" true (status.last_schedule_time = None);
    check_int "active_count defaults to 0" 0 status.active_count
;;

(* ── INFRA-057 / DEC-038 §5: a failed read is not an absent result ─────────── *)

let contains needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

(* A denied events read must be named, and must never render as "none". This is
   the state the live Run 8 diagnosis was in: the deploy identity may not read
   events, and the output said nothing about it. *)
let test_unavailable_events_are_named_not_empty () =
  match
    D.format_service_diagnosis
      ~service_name:"charge-svc"
      (D.parse_pods_json crash_loop_json)
      (D.Events_unavailable
         "Error from server (Forbidden): events is forbidden: cannot list resource \
          \"events\"")
  with
  | None -> Alcotest.fail "an unhealthy pod must be diagnosed"
  | Some text ->
    check_bool
      "the block says the events read was unavailable"
      true
      (contains "Events unavailable:" text);
    check_bool "and carries the reason" true (contains "Forbidden" text);
    check_bool
      "and does not claim there were no events"
      false
      (contains "No events recorded" text)
;;

(* The other state: the read worked and there is genuinely nothing. It must be
   distinguishable from the one above -- otherwise the operator cannot tell
   "nothing happened" from "I was not allowed to look". *)
let test_zero_events_are_reported_as_zero () =
  match
    D.format_service_diagnosis
      ~service_name:"charge-svc"
      (D.parse_pods_json crash_loop_json)
      (D.Events [])
  with
  | None -> Alcotest.fail "an unhealthy pod must be diagnosed"
  | Some text ->
    check_bool
      "the block says there were no events"
      true
      (contains "No events recorded" text);
    check_bool
      "and does not claim the read was unavailable"
      false
      (contains "Events unavailable:" text)
;;

(* End to end through the real fetch: the collapse happened in
   [fetch_namespace_events], so a rendering test alone would not have caught it. *)
let with_fake_kubectl f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
verb=""
for a in "$@"; do
  case "$a" in get|create|apply|patch|delete) verb="$a"; break ;; esac
done
if [ "$verb" = "get" ]; then
  case "$*" in
    *events*)
      echo 'Error from server (Forbidden): events is forbidden: cannot list resource "events" in API group "" in the namespace "pluto-checkout"' >&2
      exit 1 ;;
    *pods*)
      cat <<'JSON'
%s
JSON
      exit 0 ;;
  esac
fi
exit 0
|}
      crash_loop_json
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
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let test_the_fetch_distinguishes_a_denied_read () =
  with_fake_kubectl (fun () ->
    match
      D.diagnose_service_live
        ~ctx:Sol_cli_kube_destination.local_context
        ~pod_expectation:D.Continuous
        ~ns:"pluto-checkout"
        ~service_name:"charge-svc"
        ~k8s_name:"charge-svc"
        ()
    with
    | None -> Alcotest.fail "the pod is unhealthy, so a diagnosis is expected"
    | Some text ->
      check_bool
        "the denied events read reaches the output as unavailable"
        true
        (contains "Events unavailable:" text);
      check_bool
        "and is not reported as an empty event set"
        false
        (contains "No events recorded" text))
;;

let () =
  Alcotest.run
    "rollout_diagnosis"
    [ ( "parse_pods_json"
      , [ Alcotest.test_case "healthy pod" `Quick test_parse_healthy_pod
        ; Alcotest.test_case "image pull backoff" `Quick test_parse_image_pull_backoff
        ; Alcotest.test_case
            "crash loop last termination"
            `Quick
            test_parse_crash_loop_last_termination
        ; Alcotest.test_case
            "pod with no container statuses"
            `Quick
            test_parse_pod_with_no_container_statuses
        ; Alcotest.test_case
            "pod with missing status keeps list"
            `Quick
            test_parse_pod_with_missing_status_keeps_list
        ] )
    ; ( "events"
      , [ Alcotest.test_case
            "filters and orders by pod"
            `Quick
            test_events_for_pod_filters_and_orders
        ; Alcotest.test_case
            "excludes other pods"
            `Quick
            test_events_for_pod_excludes_other_pods
        ] )
    ; ( "format_service_diagnosis"
      , [ Alcotest.test_case
            "none when healthy"
            `Quick
            test_format_service_diagnosis_none_when_healthy
        ; Alcotest.test_case
            "includes events and reason"
            `Quick
            test_format_service_diagnosis_includes_events_and_reason
        ; Alcotest.test_case
            "reports empty pod list, not healthy"
            `Quick
            test_format_service_diagnosis_reports_empty_pod_list
        ; Alcotest.test_case
            "succeeded pod still flagged when Continuous"
            `Quick
            test_format_service_diagnosis_succeeded_pod_still_flagged_when_continuous
        ] )
    ; ( "format_cronjob_diagnosis"
      , [ Alcotest.test_case
            "never scheduled -> OK"
            `Quick
            test_format_cronjob_diagnosis_never_scheduled_is_ok
        ; Alcotest.test_case
            "last run succeeded -> OK"
            `Quick
            test_format_cronjob_diagnosis_last_run_succeeded_is_ok
        ; Alcotest.test_case
            "success at schedule boundary -> OK"
            `Quick
            test_format_cronjob_diagnosis_success_at_schedule_boundary_is_ok
        ; Alcotest.test_case
            "last run failed -> flagged"
            `Quick
            test_format_cronjob_diagnosis_last_run_failed_is_flagged
        ; Alcotest.test_case
            "never succeeded -> flagged"
            `Quick
            test_format_cronjob_diagnosis_never_succeeded_is_flagged
        ; Alcotest.test_case
            "active run -> OK"
            `Quick
            test_format_cronjob_diagnosis_active_run_is_ok
        ; Alcotest.test_case
            "missing CronJob -> flagged"
            `Quick
            test_format_cronjob_diagnosis_missing_is_flagged
        ; Alcotest.test_case
            "unavailable fetch stays silent"
            `Quick
            test_format_cronjob_diagnosis_unavailable_stays_silent
        ] )
    ; ( "format_active_run_diagnosis"
      , [ Alcotest.test_case
            "running pod -> OK"
            `Quick
            test_format_active_run_diagnosis_running_pod_is_ok
        ; Alcotest.test_case
            "succeeded pod -> OK"
            `Quick
            test_format_active_run_diagnosis_succeeded_pod_is_ok
        ; Alcotest.test_case
            "stuck pod -> flagged"
            `Quick
            test_format_active_run_diagnosis_stuck_pod_is_flagged
        ; Alcotest.test_case
            "pending startup -> OK"
            `Quick
            test_format_active_run_diagnosis_pending_startup_is_ok
        ; Alcotest.test_case
            "failed scheduling -> flagged"
            `Quick
            test_format_active_run_diagnosis_failed_scheduling_is_flagged
        ; Alcotest.test_case
            "container creating -> OK"
            `Quick
            test_format_active_run_diagnosis_container_creating_is_ok
        ; Alcotest.test_case
            "container creating after restart -> flagged"
            `Quick
            test_format_active_run_diagnosis_container_creating_after_restart_is_flagged
        ] )
    ; ( "parse_cronjob_status"
      , [ Alcotest.test_case "parses full status" `Quick test_parse_cronjob_status
        ; Alcotest.test_case
            "never scheduled defaults"
            `Quick
            test_parse_cronjob_status_never_scheduled
        ; Alcotest.test_case
            "status key absent entirely"
            `Quick
            test_parse_cronjob_status_status_key_absent
        ] )
    ; ( "failed reads are not absent evidence (INFRA-057)"
      , [ Alcotest.test_case
            "unavailable events are named, not empty"
            `Quick
            test_unavailable_events_are_named_not_empty
        ; Alcotest.test_case
            "zero events are reported as zero"
            `Quick
            test_zero_events_are_reported_as_zero
        ; Alcotest.test_case
            "the fetch distinguishes a denied read"
            `Quick
            test_the_fetch_distinguishes_a_denied_read
        ] )
    ]
;;
