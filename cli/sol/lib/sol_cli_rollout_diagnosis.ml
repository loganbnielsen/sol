(* Pure parsing/summarizing of kubectl pod + event JSON, used by 'sol status'
   to explain a failed rollout directly from Kubernetes state. This is the
   layer that works even when the app never started and Loki has nothing. *)

module J = Yojson.Safe.Util

type container_state =
  | Waiting     of { reason : string; message : string option }
  | Running
  | Terminated  of { reason : string; exit_code : int; message : string option }
  | Unknown_state

type pod_status = {
  name                    : string;
  phase                   : string;
  ready                   : bool;
  restarts                : int;
  image                   : string option;
  state                   : container_state;
  last_terminated_reason  : string option;
}

type event = {
  ev_type        : string;
  reason         : string;
  message        : string;
  count          : int;
  last_timestamp : string option;
  involved_name  : string;
}

let member_opt key j = try Some (J.member key j) with _ -> None
let is_null = function None | Some `Null -> true | Some _ -> false

let to_string_opt = function `String s -> Some s | _ -> None
let to_int_opt = function `Int i -> Some i | _ -> None
let to_bool_opt = function `Bool b -> Some b | _ -> None

let parse_container_state (c : Yojson.Safe.t) : container_state =
  match member_opt "state" c with
  | None -> Unknown_state
  | Some state ->
    let waiting = member_opt "waiting" state in
    let running = member_opt "running" state in
    let terminated = member_opt "terminated" state in
    if not (is_null waiting) then
      let w = Option.get waiting in
      let reason = J.member "reason" w |> to_string_opt |> Option.value ~default:"Unknown" in
      let message = J.member "message" w |> to_string_opt in
      Waiting { reason; message }
    else if not (is_null running) then
      Running
    else if not (is_null terminated) then
      let t = Option.get terminated in
      let reason = J.member "reason" t |> to_string_opt |> Option.value ~default:"Unknown" in
      let exit_code = J.member "exitCode" t |> to_int_opt |> Option.value ~default:0 in
      let message = J.member "message" t |> to_string_opt in
      Terminated { reason; exit_code; message }
    else
      Unknown_state

let parse_last_terminated_reason (c : Yojson.Safe.t) : string option =
  match member_opt "lastState" c with
  | None -> None
  | Some ls ->
    (match member_opt "terminated" ls with
     | Some t when not (is_null (Some t)) -> J.member "reason" t |> to_string_opt
     | _ -> None)

let parse_pod (item : Yojson.Safe.t) : pod_status =
  let name =
    J.member "metadata" item |> J.member "name" |> to_string_opt
    |> Option.value ~default:"unknown"
  in
  let status =
    match member_opt "status" item with
    | Some (`Assoc _ as status) -> status
    | _ -> `Assoc []
  in
  let phase = J.member "phase" status |> to_string_opt |> Option.value ~default:"Unknown" in
  let container_statuses =
    match member_opt "containerStatuses" status with
    | Some (`List l) -> l
    | _ -> []
  in
  match container_statuses with
  | [] ->
    { name; phase; ready = false; restarts = 0; image = None;
      state = Unknown_state; last_terminated_reason = None }
  | c :: _ ->
    let ready = J.member "ready" c |> to_bool_opt |> Option.value ~default:false in
    let restarts = J.member "restartCount" c |> to_int_opt |> Option.value ~default:0 in
    let image = J.member "image" c |> to_string_opt in
    let state = parse_container_state c in
    let last_terminated_reason = parse_last_terminated_reason c in
    { name; phase; ready; restarts; image; state; last_terminated_reason }

let parse_pods_json (s : string) : pod_status list =
  try
    match member_opt "items" (Yojson.Safe.from_string s) with
    | Some (`List items) -> List.map parse_pod items
    | _ -> []
  with _ -> []

let parse_event (item : Yojson.Safe.t) : event option =
  try
    let involved_name =
      J.member "involvedObject" item |> J.member "name" |> to_string_opt
      |> Option.value ~default:""
    in
    let ev_type = J.member "type" item |> to_string_opt |> Option.value ~default:"Normal" in
    let reason = J.member "reason" item |> to_string_opt |> Option.value ~default:"" in
    let message = J.member "message" item |> to_string_opt |> Option.value ~default:"" in
    let count = J.member "count" item |> to_int_opt |> Option.value ~default:1 in
    let last_timestamp = J.member "lastTimestamp" item |> to_string_opt in
    Some { ev_type; reason; message; count; last_timestamp; involved_name }
  with _ -> None

let parse_events_json (s : string) : event list =
  try
    match member_opt "items" (Yojson.Safe.from_string s) with
    | Some (`List items) -> List.filter_map parse_event items
    | _ -> []
  with _ -> []

let events_for_pod ?(limit = 5) ~pod_name (events : event list) : event list =
  events
  |> List.filter (fun e -> e.involved_name = pod_name)
  |> List.sort (fun a b -> compare a.last_timestamp b.last_timestamp)
  |> List.rev
  |> List.filteri (fun i _ -> i < limit)

let is_healthy (p : pod_status) : bool =
  p.phase = "Running" && p.ready && (p.state = Running)

type pod_expectation = Continuous | Ephemeral

let format_pod_diagnosis (p : pod_status) (events : event list) : string =
  let buf = Buffer.create 256 in
  let headline = match p.state with
    | Waiting { reason; _ } -> reason
    | Terminated { reason; _ } -> reason
    | Running | Unknown_state -> p.phase
  in
  Buffer.add_string buf (Printf.sprintf "Pod %s: %s\n" p.name headline);
  (match p.state with
   | Waiting { reason; message } ->
     Buffer.add_string buf
       (Printf.sprintf "Reason: %s%s\n" reason
          (match message with Some m -> " — " ^ m | None -> ""))
   | Terminated { reason; exit_code; message } ->
     Buffer.add_string buf
       (Printf.sprintf "Reason: %s (exit code %d)%s\n" reason exit_code
          (match message with Some m -> " — " ^ m | None -> ""))
   | Running | Unknown_state -> ());
  (match p.last_terminated_reason with
   | Some r when p.restarts > 0 -> Buffer.add_string buf (Printf.sprintf "Last termination: %s\n" r)
   | _ -> ());
  if p.restarts > 0 then Buffer.add_string buf (Printf.sprintf "Restarts: %d\n" p.restarts);
  (match p.image with
   | Some img -> Buffer.add_string buf (Printf.sprintf "Image: %s\n" img)
   | None -> ());
  if events <> [] then begin
    Buffer.add_string buf "Last events:\n";
    List.iter (fun e -> Buffer.add_string buf (Printf.sprintf "  %s: %s\n" e.reason e.message)) events
  end;
  Buffer.contents buf

let render_unhealthy_pods ~service_name (pods : pod_status list) (events : event list) : string =
  let buf = Buffer.create 512 in
  Buffer.add_string buf (Printf.sprintf "%s rollout failed\n\n" service_name);
  List.iter (fun p ->
    Buffer.add_string buf (format_pod_diagnosis p (events_for_pod ~pod_name:p.name events));
    Buffer.add_char buf '\n'
  ) pods;
  Buffer.contents buf

(* Continuous workloads should always have a pod; an empty confirmed pod
   list means the workload never started. *)
let format_service_diagnosis ~service_name
    (pods : pod_status list) (events : event list) : string option =
  if pods = [] then
    Some (Printf.sprintf "%s rollout failed\n\nNo pods found for this service.\n" service_name)
  else
    let unhealthy = List.filter (fun p -> not (is_healthy p)) pods in
    if unhealthy = [] then None
    else Some (render_unhealthy_pods ~service_name unhealthy events)

(* Beyond [is_healthy]: [Succeeded] is OK (a finishing run is expected, and
   status.active can lag one reconcile behind). A pod with zero restarts
   that's merely starting (Pending, or Waiting on ContainerCreating /
   PodInitializing) is also OK -- unless a [FailedScheduling] event names it
   (genuinely unschedulable) or it has already restarted (no longer a first
   start). *)
let is_active_run_pod_ok ~(events : event list) (p : pod_status) : bool =
  is_healthy p
  || p.phase = "Succeeded"
  || (p.restarts = 0 &&
      not (List.exists (fun e -> e.involved_name = p.name && e.reason = "FailedScheduling") events) &&
      match p.state with
      | Waiting { reason; _ } -> reason = "ContainerCreating" || reason = "PodInitializing"
      | Unknown_state -> p.phase = "Pending"
      | Running | Terminated _ -> false)

(* Scoped to exactly the Job(s) in [cronjob_status.active_job_names] -- never
   a broader/historical pod list. *)
let format_active_run_diagnosis ~service_name
    (pods : pod_status list) (events : event list) : string option =
  let unhealthy = List.filter (fun p -> not (is_active_run_pod_ok ~events p)) pods in
  if unhealthy = [] then None
  else Some (render_unhealthy_pods ~service_name unhealthy events)

type cronjob_status = {
  last_schedule_time   : string option;
  last_successful_time : string option;
  active_count         : int;
  active_job_names     : string list;
}

let parse_cronjob_status (s : string) : cronjob_status option =
  try
    let j = Yojson.Safe.from_string s in
    match J.member "status" j with
    | `Null ->
      Some {
        last_schedule_time = None;
        last_successful_time = None;
        active_count = 0;
        active_job_names = [];
      }
    | status ->
      let last_schedule_time = J.member "lastScheduleTime" status |> to_string_opt in
      let last_successful_time = J.member "lastSuccessfulTime" status |> to_string_opt in
      let active_count, active_job_names =
        match member_opt "active" status with
        | Some (`List l) ->
          List.length l, List.filter_map (fun item -> J.member "name" item |> to_string_opt) l
        | _ -> 0, []
      in
      Some { last_schedule_time; last_successful_time; active_count; active_job_names }
  with _ -> None

type cronjob_fetch_result =
  | Found of cronjob_status
  | Missing
  (** Confirmed via kubectl's own NotFound response -- not a transient
      failure. *)
  | Unavailable
  (** The kubectl call itself failed, or its output couldn't be parsed
      (transient error, timeout, RBAC, ...) -- stays silent, same as
      other transient-failure handling in this module. *)

let is_at_or_after ~reference candidate =
  match Ptime.of_rfc3339 candidate, Ptime.of_rfc3339 reference with
  | Ok (t_candidate, _, _), Ok (t_reference, _, _) -> Ptime.compare t_candidate t_reference >= 0
  | _ -> false

(* Ephemeral diagnosis uses CronJob status, not historical pod lists.
   Active-run pod health is tracked separately. *)
let format_cronjob_diagnosis ~service_name (result : cronjob_fetch_result) : string option =
  match result with
  | Unavailable -> None
  | Missing ->
    Some (Printf.sprintf "%s rollout failed\n\nCronJob not found for this service.\n" service_name)
  | Found status ->
    if status.active_count > 0 then None
    else
      match status.last_schedule_time with
      | None -> None
      | Some scheduled ->
        let succeeded_since = match status.last_successful_time with
          | Some succeeded -> is_at_or_after ~reference:scheduled succeeded
          | None -> false
        in
        if succeeded_since then None
        else
          Some (Printf.sprintf
                  "%s rollout failed\n\nMost recently scheduled run (%s) did not complete successfully.\n"
                  service_name scheduled)

let fetch_namespace_events ~ns : event list =
  match Sol_cli_kubectl.get_raw ~args:["get"; "events"; "-n"; ns; "-o"; "json"] with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> parse_events_json r.Sol_cli_process.stdout
  | _ -> []

let fetch_pod_statuses ~ns ~k8s_name : pod_status list option =
  match Sol_cli_kubectl.get_raw
          ~args:["get"; "pods"; "-n"; ns; "-l"; "app=" ^ k8s_name; "-o"; "json"] with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> Some (parse_pods_json r.Sol_cli_process.stdout)
  | _ -> None

let fetch_job_pod_statuses ~ns ~job_name : pod_status list option =
  match Sol_cli_kubectl.get_raw
          ~args:["get"; "pods"; "-n"; ns; "-l"; "job-name=" ^ job_name; "-o"; "json"] with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> Some (parse_pods_json r.Sol_cli_process.stdout)
  | _ -> None

(* Best-effort per job: one failed fetch doesn't block the others. [None]
   only when every fetch fails. *)
let fetch_active_cronjob_pods ~ns job_names : pod_status list option =
  let fetched =
    job_names
    |> List.filter_map (fun job_name -> fetch_job_pod_statuses ~ns ~job_name)
  in
  match fetched with
  | [] when job_names <> [] -> None
  | _ -> Some (List.concat fetched)

let fetch_cronjob_status ~ns ~k8s_name : cronjob_fetch_result =
  match Sol_cli_kubectl.get_raw ~args:["get"; "cronjob"; k8s_name; "-n"; ns; "-o"; "json"] with
  | Error _ -> Unavailable
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    (match parse_cronjob_status r.Sol_cli_process.stdout with
     | Some status -> Found status
     | None -> Unavailable)
  | Ok r ->
    if Sol_cli_port_forward.string_contains ~needle:"NotFound" r.Sol_cli_process.stderr
    then Missing else Unavailable

let diagnose_service_live ~pod_expectation ~ns ~service_name ~k8s_name () : string option =
  match pod_expectation with
  | Continuous ->
    (match fetch_pod_statuses ~ns ~k8s_name with
     | None -> None
     | Some pods ->
       let events = fetch_namespace_events ~ns in
       format_service_diagnosis ~service_name pods events)
  | Ephemeral ->
    let cronjob = fetch_cronjob_status ~ns ~k8s_name in
    match cronjob with
    | Found { active_job_names = _ :: _ as job_names; _ } ->
      (match fetch_active_cronjob_pods ~ns job_names with
       | Some (_ :: _ as pods) ->
         let events = fetch_namespace_events ~ns in
         format_active_run_diagnosis ~service_name pods events
       | Some [] | None -> format_cronjob_diagnosis ~service_name cronjob)
    | _ -> format_cronjob_diagnosis ~service_name cronjob
