let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

module D = Sol_cli_rollout_diagnosis

let ok what = function
  | Ok v -> v
  | Error e -> Alcotest.failf "%s: unexpected decode error: %s" what e
;;

let pods_of json = D.parse_pods_json json |> ok "pods"
let events_of json = D.parse_events_json json |> ok "events"
let contains needle haystack = Sol_cli_string.contains ~needle haystack

let reports_healthy = function
  | D.Healthy -> true
  | D.Unhealthy _ | D.Undetermined _ -> false
;;

let reports_a_problem = function
  | D.Healthy -> false
  | D.Unhealthy _ | D.Undetermined _ -> true
;;

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

let test_parse_healthy_pod () =
  match pods_of healthy_pod_json with
  | [ p ] ->
    check_string "name" "charge-svc-abc" p.name;
    check_string "phase" "Running" p.phase;
    check_bool "ready" true p.ready;
    check_int "restarts" 0 p.restarts;
    check_bool "is_healthy" true (D.is_healthy p)
  | _ -> Alcotest.fail "expected exactly one pod"
;;

let test_parse_image_pull_backoff () =
  match pods_of image_pull_backoff_json with
  | [ p ] ->
    check_bool "is_healthy" false (D.is_healthy p);
    (match p.state with
     | D.Waiting { reason; _ } -> check_string "reason" "ImagePullBackOff" reason
     | _ -> Alcotest.fail "expected Waiting state")
  | _ -> Alcotest.fail "expected exactly one pod"
;;

let test_parse_crash_loop_last_termination () =
  match pods_of crash_loop_json with
  | [ p ] ->
    check_int "restarts" 6 p.restarts;
    check_string
      "last_terminated_reason"
      "OOMKilled"
      (Option.value ~default:"none" p.last_terminated_reason)
  | _ -> Alcotest.fail "expected exactly one pod"
;;

let test_parse_pod_with_no_container_statuses () =
  match pods_of pending_no_containers_json with
  | [ p ] ->
    check_string "phase" "Pending" p.phase;
    check_bool "is_healthy" false (D.is_healthy p)
  | _ -> Alcotest.fail "expected exactly one pod"
;;

let test_parse_pod_with_missing_status_keeps_list () =
  match pods_of missing_status_pod_json with
  | [ missing; healthy ] ->
    check_string "missing name" "charge-svc-missing-status" missing.name;
    check_string "missing phase" "Unknown" missing.phase;
    check_bool "missing is unhealthy" false (D.is_healthy missing);
    check_string "healthy name" "charge-svc-abc" healthy.name;
    check_bool "healthy still parsed" true (D.is_healthy healthy)
  | pods -> Alcotest.failf "expected two pods, got %d" (List.length pods)
;;

let test_events_for_pod_filters_and_orders () =
  let events = events_of events_json in
  let for_xyz = D.events_for_pod ~pod_name:"charge-svc-xyz" events in
  check_int "two events for charge-svc-xyz" 2 (List.length for_xyz);
  check_string "most recent first" "BackOff" (List.hd for_xyz).D.reason
;;

let test_events_for_pod_excludes_other_pods () =
  let events = events_of events_json in
  let for_other = D.events_for_pod ~pod_name:"charge-svc-abc" events in
  check_int "no events for unrelated pod" 0 (List.length for_other)
;;

let test_format_service_diagnosis_none_when_healthy () =
  let pods = pods_of healthy_pod_json in
  check_bool
    "no diagnosis for healthy service"
    true
    (reports_healthy
       (D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events [])))
;;

let test_format_service_diagnosis_includes_events_and_reason () =
  let pods = pods_of image_pull_backoff_json in
  let events = events_of events_json in
  match D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events events) with
  | D.Healthy -> Alcotest.fail "expected a diagnosis"
  | D.Undetermined why ->
    Alcotest.fail ("the pod list was readable, so a verdict is expected: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (Sol_cli_string.contains ~needle:"charge-svc rollout failed" diagnosis);
    check_bool
      "mentions ImagePullBackOff"
      true
      (Sol_cli_string.contains ~needle:"ImagePullBackOff" diagnosis);
    check_bool
      "mentions FailedPull event"
      true
      (Sol_cli_string.contains ~needle:"FailedPull" diagnosis)
;;

let test_format_service_diagnosis_reports_empty_pod_list () =
  match D.format_service_diagnosis ~service_name:"charge-svc" [] (D.Events []) with
  | D.Healthy -> Alcotest.fail "expected a diagnosis for zero pods, not a healthy verdict"
  | D.Undetermined why ->
    Alcotest.fail ("the pod list was readable, so a verdict is expected: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (Sol_cli_string.contains ~needle:"charge-svc rollout failed" diagnosis);
    check_bool
      "mentions no pods found"
      true
      (Sol_cli_string.contains ~needle:"No pods found" diagnosis)
;;

let test_format_service_diagnosis_succeeded_pod_still_flagged_when_continuous () =
  let pods = pods_of succeeded_pod_json in
  check_bool
    "a Succeeded pod is still a finding for Continuous (Svc/Worker)"
    true
    (reports_a_problem
       (D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events [])))
;;

let never_scheduled : D.cronjob_status =
  { last_schedule_time = None; last_successful_time = None; active_job_names = [] }
;;

let idle_last_run_succeeded : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-02T10:00:05Z"
  ; active_job_names = []
  }
;;

let idle_last_run_failed : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-01T10:00:05Z"
  ; active_job_names = []
  }
;;

let idle_success_at_schedule_boundary : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-02T10:00:00Z"
  ; active_job_names = []
  }
;;

let idle_never_succeeded : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = None
  ; active_job_names = []
  }
;;

let run_currently_active : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = None
  ; active_job_names = [ "invoice-fn-29384710-abcde" ]
  }
;;

let test_format_cronjob_diagnosis_never_scheduled_is_ok () =
  check_bool
    "never scheduled -> no diagnosis"
    true
    (reports_healthy
       (D.format_cronjob_diagnosis ~service_name:"invoice-fn" (D.Found never_scheduled)))
;;

let test_format_cronjob_diagnosis_last_run_succeeded_is_ok () =
  check_bool
    "most recent run succeeded -> no diagnosis"
    true
    (reports_healthy
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_last_run_succeeded)))
;;

let test_format_cronjob_diagnosis_success_at_schedule_boundary_is_ok () =
  check_bool
    "success at the same instant as the schedule trigger -> no diagnosis"
    true
    (reports_healthy
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_success_at_schedule_boundary)))
;;

let test_format_cronjob_diagnosis_last_run_failed_is_flagged () =
  match
    D.format_cronjob_diagnosis ~service_name:"invoice-fn" (D.Found idle_last_run_failed)
  with
  | D.Healthy ->
    Alcotest.fail "expected a diagnosis for a most-recent-run failure, not healthy"
  | D.Undetermined why -> Alcotest.fail ("the CronJob was readable: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (Sol_cli_string.contains ~needle:"invoice-fn rollout failed" diagnosis);
    check_bool
      "mentions the schedule time"
      true
      (Sol_cli_string.contains ~needle:"2026-09-02T10:00:00Z" diagnosis)
;;

let test_format_cronjob_diagnosis_never_succeeded_is_flagged () =
  check_bool
    "scheduled but never once succeeded -> flagged"
    true
    (reports_a_problem
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_never_succeeded)))
;;

let test_format_cronjob_diagnosis_active_run_is_ok () =
  check_bool
    "a currently-active run is not (yet) a diagnosis"
    true
    (reports_healthy
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found run_currently_active)))
;;

let test_format_cronjob_diagnosis_missing_is_flagged () =
  match D.format_cronjob_diagnosis ~service_name:"invoice-fn" D.Missing with
  | D.Healthy -> Alcotest.fail "expected a diagnosis for a missing CronJob, not healthy"
  | D.Undetermined why -> Alcotest.fail ("the CronJob read succeeded: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (Sol_cli_string.contains ~needle:"invoice-fn rollout failed" diagnosis);
    check_bool
      "mentions not found"
      true
      (Sol_cli_string.contains ~needle:"not found" diagnosis)
;;

let test_format_cronjob_diagnosis_unavailable_is_undetermined () =
  match
    D.format_cronjob_diagnosis
      ~service_name:"invoice-fn"
      (D.Unavailable "the kubectl call failed")
  with
  | D.Undetermined why ->
    check_bool "the verdict carries why" true (contains "kubectl call failed" why)
  | D.Healthy -> Alcotest.fail "a failed read must not be reported as healthy"
  | D.Unhealthy _ -> Alcotest.fail "a failed read is not a rollout failure either"
;;

let test_format_active_run_diagnosis_running_pod_is_ok () =
  let pods = pods_of healthy_pod_json in
  check_bool
    "a Running, ready pod is not a finding"
    true
    (reports_healthy
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_succeeded_pod_is_ok () =
  let pods = pods_of succeeded_pod_json in
  check_bool
    "a Succeeded active-run pod is not a finding"
    true
    (reports_healthy
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_stuck_pod_is_flagged () =
  let pods = pods_of image_pull_backoff_json in
  check_bool
    "a stuck (ImagePullBackOff) active-run pod is a finding"
    true
    (reports_a_problem
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_pending_startup_is_ok () =
  let pods = pods_of pending_no_containers_json in
  check_bool
    "a freshly-scheduled pod with no container status yet is not a finding"
    true
    (reports_healthy
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_failed_scheduling_is_flagged () =
  let pods = pods_of pending_no_containers_json in
  let events = events_of events_json in
  check_bool
    "a FailedScheduling pod is still a finding despite looking like normal startup"
    true
    (reports_a_problem
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events events)))
;;

let test_format_active_run_diagnosis_container_creating_is_ok () =
  let pods = pods_of container_creating_json in
  check_bool
    "ContainerCreating with no restarts is not a finding"
    true
    (reports_healthy
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_container_creating_after_restart_is_flagged () =
  let pods = pods_of container_creating_after_restart_json in
  check_bool
    "ContainerCreating after a restart is still a finding"
    true
    (reports_a_problem
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_parse_cronjob_status () =
  let json =
    {|{"status": {"lastScheduleTime": "2026-09-02T10:00:00Z", "lastSuccessfulTime": "2026-09-02T10:00:05Z", "active": [{"name": "invoice-fn-1"}]}}|}
  in
  match D.parse_cronjob_status json with
  | Error e -> Alcotest.fail ("expected a cronjob_status: " ^ e)
  | Ok (status : D.cronjob_status) ->
    check_string
      "lastScheduleTime"
      "2026-09-02T10:00:00Z"
      (Option.value ~default:"" status.last_schedule_time);
    check_string
      "lastSuccessfulTime"
      "2026-09-02T10:00:05Z"
      (Option.value ~default:"" status.last_successful_time);
    check_string
      "active_job_names"
      "invoice-fn-1"
      (match status.active_job_names with
       | [ name ] -> name
       | _ -> "")
;;

let test_parse_cronjob_status_never_scheduled () =
  match D.parse_cronjob_status {|{"status": {}}|} with
  | Error e -> Alcotest.fail ("expected a cronjob_status: " ^ e)
  | Ok (status : D.cronjob_status) ->
    check_bool "no lastScheduleTime" true (status.last_schedule_time = None);
    check_int "no active jobs" 0 (List.length status.active_job_names)
;;

let test_parse_cronjob_status_status_key_absent () =
  match D.parse_cronjob_status {|{}|} with
  | Error e -> Alcotest.fail ("expected a cronjob_status, got Unavailable: " ^ e)
  | Ok (status : D.cronjob_status) ->
    check_bool "no lastScheduleTime" true (status.last_schedule_time = None);
    check_int "no active jobs" 0 (List.length status.active_job_names)
;;

let is_error = function
  | Ok _ -> false
  | Error _ -> true
;;

let test_malformed_reads_are_errors () =
  check_bool "pods: not JSON" true (is_error (D.parse_pods_json "not json"));
  check_bool "pods: no items" true (is_error (D.parse_pods_json {|{"kind": "Status"}|}));
  check_bool
    "pods: item not an object"
    true
    (is_error (D.parse_pods_json {|{"items": [1]}|}));
  check_bool "events: not JSON" true (is_error (D.parse_events_json "<html>"));
  check_bool
    "events: items not a list"
    true
    (is_error (D.parse_events_json {|{"items": {}}|}));
  check_bool "cronjob: not JSON" true (is_error (D.parse_cronjob_status ""));
  check_bool
    "cronjob: active not a list"
    true
    (is_error (D.parse_cronjob_status {|{"status": {"active": "x"}}|}));
  check_bool
    "cronjob: active job with no name"
    true
    (is_error (D.parse_cronjob_status {|{"status": {"active": [{}]}}|}))
;;

let test_empty_lists_are_answers () =
  check_int "no pods" 0 (List.length (pods_of {|{"items": []}|}));
  check_int "no events" 0 (List.length (events_of {|{"items": []}|}))
;;

let test_pod_without_metadata_parses () =
  match pods_of {|{"items": [{"status": {"phase": "Pending"}}]}|} with
  | [ p ] ->
    check_string "name defaults" "unknown" p.name;
    check_string "phase" "Pending" p.phase
  | _ -> Alcotest.fail "expected one pod"
;;

let contains needle haystack = Sol_cli_string.contains ~needle haystack

let test_unavailable_events_are_named_not_empty () =
  match
    D.format_service_diagnosis
      ~service_name:"charge-svc"
      (pods_of crash_loop_json)
      (D.Events_unavailable
         "Error from server (Forbidden): events is forbidden: cannot list resource \
          \"events\"")
  with
  | D.Healthy -> Alcotest.fail "an unhealthy pod must be diagnosed"
  | D.Undetermined why ->
    Alcotest.fail ("the pod list was readable, so this should be a diagnosis: " ^ why)
  | D.Unhealthy text ->
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

let test_zero_events_are_reported_as_zero () =
  match
    D.format_service_diagnosis
      ~service_name:"charge-svc"
      (pods_of crash_loop_json)
      (D.Events [])
  with
  | D.Healthy -> Alcotest.fail "an unhealthy pod must be diagnosed"
  | D.Undetermined why ->
    Alcotest.fail ("the pod list was readable, so this should be a diagnosis: " ^ why)
  | D.Unhealthy text ->
    check_bool
      "the block says there were no events"
      true
      (contains "No events recorded" text);
    check_bool
      "and does not claim the read was unavailable"
      false
      (contains "Events unavailable:" text)
;;

let with_fake_kubectl ?(deny = "events") f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
verb=""
deny='%s'
for a in "$@"; do
  case "$a" in get|create|apply|patch|delete) verb="$a"; break ;; esac
done
if [ "$verb" = "get" ]; then
  case "$*" in
    *pods*)
      if [ "$deny" = "pods" ]; then
        echo 'Error from server (Forbidden): pods is forbidden: User "arn:aws:sts::111122223333:assumed-role/sol-operator/EKSGetTokenAuth" cannot list resource "pods" in API group "" in the namespace "pluto-comms"' >&2
        exit 1
      fi
      cat <<'JSON'
%s
JSON
      exit 0 ;;
    *events*)
      if [ "$deny" = "events" ]; then
        echo 'Error from server (Forbidden): events is forbidden: cannot list resource "events" in API group "" in the namespace "pluto-checkout"' >&2
        exit 1
      fi
      echo '{"items":[]}'
      exit 0 ;;
  esac
fi
exit 0
|}
      deny
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
    | D.Healthy -> Alcotest.fail "the pod is unhealthy, so a diagnosis is expected"
    | D.Undetermined why ->
      Alcotest.fail ("the pod list was readable, so a verdict is expected: " ^ why)
    | D.Unhealthy text ->
      check_bool
        "the denied events read reaches the output as unavailable"
        true
        (contains "Events unavailable:" text);
      check_bool
        "and is not reported as an empty event set"
        false
        (contains "No events recorded" text))
;;

let test_an_unreadable_workload_is_undetermined_not_healthy () =
  with_fake_kubectl ~deny:"pods" (fun () ->
    match
      D.diagnose_service_live
        ~ctx:Sol_cli_kube_destination.local_context
        ~pod_expectation:D.Continuous
        ~ns:"pluto-comms"
        ~service_name:"notify-worker"
        ~k8s_name:"notify-worker"
        ()
    with
    | D.Undetermined why ->
      check_bool
        "the verdict says the workload could not be read"
        true
        (contains "could not be read" why);
      check_bool "and carries the server's reason" true (contains "Forbidden" why)
    | D.Healthy ->
      Alcotest.fail "an unreadable workload must never be reported healthy (FND-0019)"
    | D.Unhealthy _ ->
      Alcotest.fail "a read that did not happen is not a rollout failure either")
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
            "an unavailable fetch is Undetermined, not healthy"
            `Quick
            test_format_cronjob_diagnosis_unavailable_is_undetermined
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
    ; ( "malformed reads are errors (REFAC-127)"
      , [ Alcotest.test_case "malformed is Error" `Quick test_malformed_reads_are_errors
        ; Alcotest.test_case "empty list is an answer" `Quick test_empty_lists_are_answers
        ; Alcotest.test_case
            "pod without metadata parses"
            `Quick
            test_pod_without_metadata_parses
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
        ; Alcotest.test_case
            "an unreadable workload is Undetermined, never healthy"
            `Quick
            test_an_unreadable_workload_is_undetermined_not_healthy
        ] )
    ]
;;
