(* Pure parsing/summarizing of kubectl pod + event JSON, used by 'sol status'
   to explain a failed rollout directly from Kubernetes state. This is the
   layer that works even when the app never started and Loki has nothing. *)

module J = Yojson.Safe.Util

type container_state =
  | Waiting of
      { reason : string
      ; message : string option
      }
  | Running
  | Terminated of
      { reason : string
      ; exit_code : int
      ; message : string option
      }
  | Unknown_state

type pod_status =
  { name : string
  ; phase : string
  ; ready : bool
  ; restarts : int
  ; image : string option
  ; state : container_state
  ; last_terminated_reason : string option
  }

type event =
  { ev_type : string
  ; reason : string
  ; message : string
  ; count : int
  ; last_timestamp : string option
  ; involved_name : string
  }

(* REFAC-127: field access is total -- an absent field, or a path through a
   non-object, is [`Null] -- so nothing below the decode boundary can raise, and
   there is no catch-all turning a malformed read into "nothing there". *)
let rec field path (j : Yojson.Safe.t) : Yojson.Safe.t =
  match path, j with
  | [], j -> j
  | key :: rest, `Assoc fields ->
    field rest (Option.value (List.assoc_opt key fields) ~default:`Null)
  | _ :: _, _ -> `Null
;;

let to_string_opt = function
  | `String s -> Some s
  | _ -> None
;;

let to_int_opt = function
  | `Int i -> Some i
  | _ -> None
;;

let to_bool_opt = function
  | `Bool b -> Some b
  | _ -> None
;;

let string_field path j = field path j |> to_string_opt

(* The decode boundary: the text is JSON, and a list resource's [items] is a list
   of objects. Anything else is an error that names what was being read. *)
let decode ~what s =
  match Yojson.Safe.from_string s with
  | json -> Ok json
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "%s: not JSON (%s)" what msg)
;;

let items ~what s =
  let ( let* ) = Result.bind in
  let* json = decode ~what s in
  match field [ "items" ] json with
  | `List items ->
    Sol_cli_result.map_list
      (function
        | `Assoc _ as item -> Ok item
        | _ -> Error (Printf.sprintf "%s: an item is not an object" what))
      items
  | _ -> Error (Printf.sprintf "%s: the response has no items list" what)
;;

let parse_container_state (c : Yojson.Safe.t) : container_state =
  let reason j = string_field [ "reason" ] j |> Option.value ~default:"Unknown" in
  let message j = string_field [ "message" ] j in
  match field [ "state"; "waiting" ] c, field [ "state"; "running" ] c with
  | (`Assoc _ as w), _ -> Waiting { reason = reason w; message = message w }
  | _, `Assoc _ -> Running
  | _ ->
    (match field [ "state"; "terminated" ] c with
     | `Assoc _ as t ->
       let exit_code = field [ "exitCode" ] t |> to_int_opt |> Option.value ~default:0 in
       Terminated { reason = reason t; exit_code; message = message t }
     | _ -> Unknown_state)
;;

let parse_last_terminated_reason (c : Yojson.Safe.t) : string option =
  string_field [ "lastState"; "terminated"; "reason" ] c
;;

let parse_pod (item : Yojson.Safe.t) : pod_status =
  let name =
    string_field [ "metadata"; "name" ] item |> Option.value ~default:"unknown"
  in
  let phase =
    string_field [ "status"; "phase" ] item |> Option.value ~default:"Unknown"
  in
  match field [ "status"; "containerStatuses" ] item with
  | `List (c :: _) ->
    { name
    ; phase
    ; ready = field [ "ready" ] c |> to_bool_opt |> Option.value ~default:false
    ; restarts = field [ "restartCount" ] c |> to_int_opt |> Option.value ~default:0
    ; image = string_field [ "image" ] c
    ; state = parse_container_state c
    ; last_terminated_reason = parse_last_terminated_reason c
    }
  (* No container has reported yet (a pending pod). *)
  | _ ->
    { name
    ; phase
    ; ready = false
    ; restarts = 0
    ; image = None
    ; state = Unknown_state
    ; last_terminated_reason = None
    }
;;

(* [Ok []] only when the API answered with an empty list. *)
let parse_pods_json (s : string) : (pod_status list, string) result =
  items ~what:"pods" s |> Result.map (List.map parse_pod)
;;

let parse_event (item : Yojson.Safe.t) : event =
  { ev_type = string_field [ "type" ] item |> Option.value ~default:"Normal"
  ; reason = string_field [ "reason" ] item |> Option.value ~default:""
  ; message = string_field [ "message" ] item |> Option.value ~default:""
  ; count = field [ "count" ] item |> to_int_opt |> Option.value ~default:1
  ; last_timestamp = string_field [ "lastTimestamp" ] item
  ; involved_name =
      string_field [ "involvedObject"; "name" ] item |> Option.value ~default:""
  }
;;

let parse_events_json (s : string) : (event list, string) result =
  items ~what:"events" s |> Result.map (List.map parse_event)
;;

let events_for_pod ?(limit = 5) ~pod_name (events : event list) : event list =
  events
  |> List.filter (fun e -> e.involved_name = pod_name)
  |> List.sort (fun a b -> compare a.last_timestamp b.last_timestamp)
  |> List.rev
  |> List.filteri (fun i _ -> i < limit)
;;

let is_healthy (p : pod_status) : bool =
  p.phase = "Running" && p.ready && p.state = Running
;;

type pod_expectation =
  | Continuous
  | Ephemeral

(* INFRA-057 / DEC-038 §5: a *failed* read is not an empty result.

   The two states must never collapse into one another:

   - [Events []] -- the read succeeded and there is nothing to report;
   - [Events_unavailable why] -- Sol could not look, and says so.

   The status contract stays best-effort (one denied read must not deny the
   operator the rest of the diagnosis), but it must never present a part it did
   not obtain as though it had. [cronjob_fetch_result] below already had this
   shape; this is the same discipline for events. *)
type events_fetch_result =
  | Events of event list
  | Events_unavailable of string

let format_pod_diagnosis (p : pod_status) (events : events_fetch_result) : string =
  let buf = Buffer.create 256 in
  let with_message = function
    | Some m -> " — " ^ m
    | None -> ""
  in
  (* The headline and its detail line, from one look at the state. *)
  let headline, detail =
    match p.state with
    | Waiting { reason; message } ->
      reason, Some (Printf.sprintf "Reason: %s%s\n" reason (with_message message))
    | Terminated { reason; exit_code; message } ->
      ( reason
      , Some
          (Printf.sprintf
             "Reason: %s (exit code %d)%s\n"
             reason
             exit_code
             (with_message message)) )
    | Running | Unknown_state -> p.phase, None
  in
  Buffer.add_string buf (Printf.sprintf "Pod %s: %s\n" p.name headline);
  Option.iter (Buffer.add_string buf) detail;
  (match p.last_terminated_reason with
   | Some r when p.restarts > 0 ->
     Buffer.add_string buf (Printf.sprintf "Last termination: %s\n" r)
   | _ -> ());
  if p.restarts > 0
  then Buffer.add_string buf (Printf.sprintf "Restarts: %d\n" p.restarts);
  (match p.image with
   | Some img -> Buffer.add_string buf (Printf.sprintf "Image: %s\n" img)
   | None -> ());
  (match events with
   | Events [] -> Buffer.add_string buf "No events recorded for this pod.\n"
   | Events l ->
     Buffer.add_string buf "Last events:\n";
     l
     |> List.iter (fun e ->
       Buffer.add_string buf (Printf.sprintf "  %s: %s\n" e.reason e.message))
   | Events_unavailable why ->
     (* Named, never silent: this is the difference between "nothing happened"
        and "I was not allowed to look". *)
     Buffer.add_string buf (Printf.sprintf "Events unavailable: %s\n" why));
  Buffer.contents buf
;;

(* The events for one pod, keeping the unavailable state intact so the caller
   cannot accidentally render a failed read as "none". *)
let events_for_pod_result ~pod_name (result : events_fetch_result) : events_fetch_result =
  match result with
  | Events l -> Events (events_for_pod ~pod_name l)
  | Events_unavailable _ as unavailable -> unavailable
;;

let render_unhealthy_pods
      ~service_name
      (pods : pod_status list)
      (events : events_fetch_result)
  : string
  =
  let buf = Buffer.create 512 in
  Buffer.add_string buf (Printf.sprintf "%s rollout failed\n\n" service_name);
  pods
  |> List.iter (fun p ->
    Buffer.add_string
      buf
      (format_pod_diagnosis p (events_for_pod_result ~pod_name:p.name events));
    Buffer.add_char buf '\n');
  Buffer.contents buf
;;

(* DEC-038 §7: the evidence behind a verdict.

   [Healthy] and [Unhealthy] both mean the evidence was *obtained*; they differ
   only in what it says. [Undetermined] means it could not be obtained, and carries
   why. The old [string option] used [None] for [Healthy] *and* for "could not
   read", so an unreadable workload was reported as healthy -- absence and
   inability to observe sharing one representation. They no longer do. *)
type diagnosis =
  | Healthy
  | Unhealthy of string
  | Undetermined of string

(* Continuous workloads should always have a pod; an empty confirmed pod
   list means the workload never started. *)
let format_service_diagnosis
      ~service_name
      (pods : pod_status list)
      (events : events_fetch_result)
  : diagnosis
  =
  if pods = []
  then
    Unhealthy
      (Printf.sprintf
         "%s rollout failed\n\nNo pods found for this service.\n"
         service_name)
  else (
    let unhealthy = List.filter (fun p -> not (is_healthy p)) pods in
    if unhealthy = []
    then Healthy
    else Unhealthy (render_unhealthy_pods ~service_name unhealthy events))
;;

(* Beyond [is_healthy]: [Succeeded] is OK (a finishing run is expected, and
   status.active can lag one reconcile behind). A pod with zero restarts
   that's merely starting (Pending, or Waiting on ContainerCreating /
   PodInitializing) is also OK -- unless a [FailedScheduling] event names it
   (genuinely unschedulable) or it has already restarted (no longer a first
   start). *)
let is_active_run_pod_ok ~(events : events_fetch_result) (p : pod_status) : bool =
  is_healthy p
  || p.phase = "Succeeded"
  || (p.restarts = 0
      && (match events with
          (* DEC-038 §5: with no evidence, a merely-starting pod is not assumed
             fine. An unreadable event stream cannot rule out FailedScheduling,
             so it makes a pod need explanation rather than letting it pass --
             and the renderer then says the events were unavailable. *)
          | Events_unavailable _ -> false
          | Events l ->
            not
              (l
               |> List.exists (fun e ->
                 e.involved_name = p.name && e.reason = "FailedScheduling")))
      &&
      match p.state with
      | Waiting { reason; _ } ->
        reason = "ContainerCreating" || reason = "PodInitializing"
      | Unknown_state -> p.phase = "Pending"
      | Running | Terminated _ -> false)
;;

(* Scoped to exactly the Job(s) in [cronjob_status.active_job_names] -- never
   a broader/historical pod list. *)
let format_active_run_diagnosis
      ~service_name
      (pods : pod_status list)
      (events : events_fetch_result)
  : diagnosis
  =
  let unhealthy = List.filter (fun p -> not (is_active_run_pod_ok ~events p)) pods in
  if unhealthy = []
  then Healthy
  else Unhealthy (render_unhealthy_pods ~service_name unhealthy events)
;;

(* Kubernetes omits [status.active] when no job is running (omitempty), so an
   absent list is the answer "none active", not a missing value. *)
type cronjob_status =
  { last_schedule_time : string option
  ; last_successful_time : string option
  ; active_job_names : string list
  }

let parse_cronjob_status (s : string) : (cronjob_status, string) result =
  let ( let* ) = Result.bind in
  let* j = decode ~what:"the CronJob" s in
  let status = field [ "status" ] j in
  let* active_job_names =
    match field [ "active" ] status with
    | `Null -> Ok []
    | `List active ->
      Sol_cli_result.map_list
        (fun item ->
           Option.to_result
             ~none:"the CronJob: an active job has no name"
             (string_field [ "name" ] item))
        active
    | _ -> Error "the CronJob: status.active is not a list"
  in
  Ok
    { last_schedule_time = string_field [ "lastScheduleTime" ] status
    ; last_successful_time = string_field [ "lastSuccessfulTime" ] status
    ; active_job_names
    }
;;

type cronjob_fetch_result =
  | Found of cronjob_status
  | Missing
  (** Confirmed via kubectl's own NotFound response -- not a transient
          failure. *)
  | Unavailable of string
  (** The kubectl call itself failed, or its output couldn't be parsed, and this
          carries why -- a failed read is not an absent CronJob (DEC-038 §7).
          (transient error, timeout, RBAC, ...) -- stays silent, same as other
          transient-failure handling in this module. *)

let is_at_or_after ~reference candidate =
  match Ptime.of_rfc3339 candidate, Ptime.of_rfc3339 reference with
  | Ok (t_candidate, _, _), Ok (t_reference, _, _) ->
    Ptime.compare t_candidate t_reference >= 0
  | _ -> false
;;

(* Ephemeral diagnosis uses CronJob status, not historical pod lists.
   Active-run pod health is tracked separately. *)
let format_cronjob_diagnosis ~service_name (result : cronjob_fetch_result) : diagnosis =
  match result with
  (* DEC-038 §7: a failed read is not a verdict. This arm used to be [None] --
     which the rollup read as healthy. *)
  | Unavailable why ->
    Undetermined (Printf.sprintf "the CronJob's status could not be read: %s" why)
  | Missing ->
    Unhealthy
      (Printf.sprintf
         "%s rollout failed\n\nCronJob not found for this service.\n"
         service_name)
  | Found status ->
    if status.active_job_names <> []
    then Healthy
    else (
      match status.last_schedule_time with
      | None -> Healthy
      | Some scheduled ->
        let succeeded_since =
          match status.last_successful_time with
          | Some succeeded -> is_at_or_after ~reference:scheduled succeeded
          | None -> false
        in
        if succeeded_since
        then Healthy
        else
          Unhealthy
            (Printf.sprintf
               "%s rollout failed\n\n\
                Most recently scheduled run (%s) did not complete successfully.\n"
               service_name
               scheduled))
;;

let fetch_namespace_events ~ctx ~ns : events_fetch_result =
  match
    Sol_cli_kubectl.get_raw ~ctx ~args:[ "get"; "events"; "-n"; ns; "-o"; "json" ]
  with
  | Ok r ->
    (match parse_events_json r.Sol_cli_process.stdout with
     | Ok events -> Events events
     | Error why -> Events_unavailable why)
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim (r.stderr ^ " " ^ r.stdout) in
    Events_unavailable
      (if String.equal detail ""
       then Printf.sprintf "kubectl get events exited with code %d" r.exit_code
       else detail)
  | Error e -> Events_unavailable (Sol_cli_process.error_to_string e)
;;

(* DEC-038 §7: the reason travels with the failure, so a verdict can say it could
   not look rather than implying it looked and found nothing. *)
let kubectl_read_failure ~what ~exit_code ~stdout ~stderr =
  let detail = String.trim (stderr ^ " " ^ stdout) in
  Printf.sprintf
    "%s could not be read%s"
    what
    (if String.equal detail ""
     then Printf.sprintf " (exit %d)" exit_code
     else ": " ^ detail)
;;

let fetch_pod_statuses ~ctx ~ns ~k8s_name : (pod_status list, string) result =
  match
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "pods"; "-n"; ns; "-l"; "app=" ^ k8s_name; "-o"; "json" ]
  with
  | Ok r -> parse_pods_json r.Sol_cli_process.stdout
  | Error (Sol_cli_process.Non_zero r) ->
    Error
      (kubectl_read_failure
         ~what:"pods"
         ~exit_code:r.exit_code
         ~stdout:r.stdout
         ~stderr:r.stderr)
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

let fetch_job_pod_statuses ~ctx ~ns ~job_name : (pod_status list, string) result =
  match
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "pods"; "-n"; ns; "-l"; "job-name=" ^ job_name; "-o"; "json" ]
  with
  | Ok r -> parse_pods_json r.Sol_cli_process.stdout
  | Error (Sol_cli_process.Non_zero r) ->
    Error
      (kubectl_read_failure
         ~what:"the run's pods"
         ~exit_code:r.exit_code
         ~stdout:r.stdout
         ~stderr:r.stderr)
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

(* Best-effort per job: one failed fetch doesn't block the others. An error only
   when every fetch fails, and then it carries the reason. *)
let fetch_active_cronjob_pods ~ctx ~ns job_names : (pod_status list, string) result =
  let results =
    List.map (fun job_name -> fetch_job_pod_statuses ~ctx ~ns ~job_name) job_names
  in
  let fetched =
    List.filter_map
      (function
        | Ok pods -> Some pods
        | Error _ -> None)
      results
  in
  match fetched with
  | [] when job_names <> [] ->
    let reasons =
      List.filter_map
        (function
          | Error why -> Some why
          | Ok _ -> None)
        results
      |> List.sort_uniq String.compare
    in
    Error (String.concat "; " reasons)
  | _ -> Ok (List.concat fetched)
;;

let fetch_cronjob_status ~ctx ~ns ~k8s_name : cronjob_fetch_result =
  match
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "cronjob"; k8s_name; "-n"; ns; "-o"; "json" ]
  with
  | Ok r ->
    (match parse_cronjob_status r.Sol_cli_process.stdout with
     | Ok status -> Found status
     | Error why -> Unavailable why)
  | Error e ->
    (match Sol_cli_kubectl.classify e, e with
     | Not_found, _ -> Missing
     | _, Sol_cli_process.Non_zero r ->
       Unavailable
         (kubectl_read_failure
            ~what:"the CronJob"
            ~exit_code:r.exit_code
            ~stdout:r.stdout
            ~stderr:r.stderr)
     | _, e -> Unavailable (Sol_cli_process.error_to_string e))
;;

(* FEAT-063: diagnosis is cluster IO, so the destination-side context reaches
   every fetch through [ctx]. *)
let diagnose_service_live ~ctx ~pod_expectation ~ns ~service_name ~k8s_name () : diagnosis
  =
  match pod_expectation with
  | Continuous ->
    (match fetch_pod_statuses ~ctx ~ns ~k8s_name with
     (* Could not look: [Undetermined], never [Healthy]. *)
     | Error why -> Undetermined why
     | Ok pods ->
       let events = fetch_namespace_events ~ctx ~ns in
       format_service_diagnosis ~service_name pods events)
  | Ephemeral ->
    let cronjob = fetch_cronjob_status ~ctx ~ns ~k8s_name in
    (match cronjob with
     | Found { active_job_names = _ :: _ as job_names; _ } ->
       (match fetch_active_cronjob_pods ~ctx ~ns job_names with
        | Ok (_ :: _ as pods) ->
          let events = fetch_namespace_events ~ctx ~ns in
          format_active_run_diagnosis ~service_name pods events
        | Ok [] -> format_cronjob_diagnosis ~service_name cronjob
        | Error why ->
          Undetermined (Printf.sprintf "the active run's pods could not be read: %s" why))
     | _ -> format_cronjob_diagnosis ~service_name cronjob)
;;
