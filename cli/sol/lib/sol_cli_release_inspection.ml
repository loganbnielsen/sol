type rollout_status =
  | Rollout_not_started
  | Rollout_progressing
  | Rollout_succeeded
  | Rollout_failed
  | Rollout_unknown

type health_status =
  | Health_unknown
  | Health_healthy
  | Health_degraded
  | Health_unhealthy

type release_state = Queued | Building | Live | Failed | Mock_submitted

type deployment_plan_summary = {
  workspace : string;
  environment : string;
  mode : Sol_cli_deployment_plan.deployment_mode;
  image_tag : string;
  service_count : int;
  topic_count : int;
  migration_count : int;
}

type image_ref = { service_name : string; image : string }

type affected_service = {
  service_name : string;
  namespace : string;
  primitive : Sol_cli_deployment_plan.primitive;
  image : string;
  rollout_status : rollout_status;
  health_status : health_status;
  error_reason : string option;
  default_url : string option;
}

type release_summary = {
  release_id : string;
  environment_id : string;
  environment_name : string;
  status : release_state;
  plan : deployment_plan_summary;
  image_refs : image_ref list;
  services : affected_service list;
}

type rendered_manifest = {
  name : string;
  namespace : string;
  kind : string;
  yaml : string;
}

type diagnostic_event = {
  source : string;
  reason : string;
  message : string;
  severity : string;
}

type diagnostics = {
  release : release_summary;
  rendered_manifests : rendered_manifest list;
  reconciliation_events : diagnostic_event list;
  rollout_resources : string list;
  kubernetes_events : diagnostic_event list;
  raw_failure_details : string option;
}

let rollout_status_to_string = function
  | Rollout_not_started -> "not_started"
  | Rollout_progressing -> "progressing"
  | Rollout_succeeded -> "succeeded"
  | Rollout_failed -> "failed"
  | Rollout_unknown -> "unknown"

let health_status_to_string = function
  | Health_unknown -> "unknown"
  | Health_healthy -> "healthy"
  | Health_degraded -> "degraded"
  | Health_unhealthy -> "unhealthy"

let release_state_to_string = function
  | Queued -> "queued"
  | Building -> "building"
  | Live -> "live"
  | Failed -> "failed"
  | Mock_submitted -> "mock_submitted"

let mode_to_string = Sol_cli_deployment_plan.mode_to_string
let primitive_to_string = Sol_cli_deployment_plan.primitive_to_string

let deployment_plan_summary (plan : Sol_cli_deployment_plan.t) =
  {
    workspace = plan.workspace;
    environment = plan.environment.name;
    mode = plan.environment.mode;
    image_tag = plan.environment.image_tag;
    service_count = List.length plan.services;
    topic_count = List.length plan.topics;
    migration_count = List.length plan.migrations;
  }

let affected_service ?(rollout_status = Rollout_unknown)
    ?(health_status = Health_unknown) ?error_reason ?default_url ~image
    (service : Sol_cli_deployment_plan.service_spec) =
  {
    service_name = Sol_cli_deployment_plan.k8s_name_to_string service.k8s_name;
    namespace = Sol_cli_deployment_plan.namespace_to_string service.namespace;
    primitive = service.primitive;
    image;
    rollout_status;
    health_status;
    error_reason;
    default_url;
  }

let release_summary ~release_id ~environment_id ~environment_name ~status ~plan
    ~image_refs ~services =
  {
    release_id;
    environment_id;
    environment_name;
    status;
    plan = deployment_plan_summary plan;
    image_refs;
    services;
  }

let split_manifest_docs yaml =
  yaml |> String.split_on_char '\n'
  |> List.fold_left
       (fun (current, docs) line ->
         if String.trim line = "---" then
           if current = [] then ([], docs)
           else ([], String.concat "\n" (List.rev current) :: docs)
         else (line :: current, docs))
       ([], [])
  |> fun (current, docs) ->
  let docs =
    if current = [] then docs else String.concat "\n" (List.rev current) :: docs
  in
  docs |> List.rev |> List.map String.trim |> List.filter (fun doc -> doc <> "")

let field_after_prefix ~prefix doc =
  doc |> String.split_on_char '\n'
  |> List.find_map (fun line ->
      let line = String.trim line in
      if String.starts_with ~prefix line then
        Some
          (String.trim
             (String.sub line (String.length prefix)
                (String.length line - String.length prefix)))
      else None)

let manifest_kind yaml =
  field_after_prefix ~prefix:"kind:" yaml |> Option.value ~default:"Unknown"

let manifest_name yaml =
  field_after_prefix ~prefix:"name:" yaml |> Option.value ~default:"unknown"

let rendered_manifests_of_service ~workspace ?env
    ?(secret_backend = Sol_cli_manifest.Kubernetes_placeholder) service =
  (* Default to Kubernetes_placeholder for diagnostics so that
     rendered_manifests_of_plan can be called without live env vars. *)
  match
    Sol_cli_deployment_render.render_spec ~workspace ?env ~secret_backend
      service
  with
  | Error msg -> failwith msg
  | Ok (namespace_yaml, workload_yaml) ->
      split_manifest_docs (namespace_yaml ^ "\n" ^ workload_yaml)
      |> List.map (fun yaml ->
          {
            name = manifest_name yaml;
            namespace =
              Sol_cli_deployment_plan.namespace_to_string service.namespace;
            kind = manifest_kind yaml;
            yaml;
          })

let rendered_manifests_of_plan (plan : Sol_cli_deployment_plan.t) =
  List.concat_map
    (rendered_manifests_of_service ~workspace:plan.workspace
       ?env:plan.environment.Sol_cli_deployment_plan.env
       ~secret_backend:plan.environment.Sol_cli_deployment_plan.secret_backend)
    plan.services

let diagnostics ?(rendered_manifests = []) ?(reconciliation_events = [])
    ?(rollout_resources = []) ?(kubernetes_events = []) ?raw_failure_details
    release =
  {
    release;
    rendered_manifests;
    reconciliation_events;
    rollout_resources;
    kubernetes_events;
    raw_failure_details;
  }

let deployment_plan_summary_to_json p =
  `Assoc
    [
      ("workspace", `String p.workspace);
      ("environment", `String p.environment);
      ("mode", `String (mode_to_string p.mode));
      ("image_tag", `String p.image_tag);
      ("service_count", `Int p.service_count);
      ("topic_count", `Int p.topic_count);
      ("migration_count", `Int p.migration_count);
    ]

let image_ref_to_json (ref : image_ref) =
  `Assoc
    [ ("service_name", `String ref.service_name); ("image", `String ref.image) ]

let affected_service_to_json service =
  let fields =
    [
      ("service_name", `String service.service_name);
      ("namespace", `String service.namespace);
      ("primitive", `String (primitive_to_string service.primitive));
      ("image", `String service.image);
      ( "rollout_status",
        `String (rollout_status_to_string service.rollout_status) );
      ("health_status", `String (health_status_to_string service.health_status));
    ]
  in
  let fields =
    match service.error_reason with
    | None -> fields
    | Some reason -> fields @ [ ("error_reason", `String reason) ]
  in
  let fields =
    match service.default_url with
    | None -> fields
    | Some url -> fields @ [ ("default_url", `String url) ]
  in
  `Assoc fields

let release_summary_to_json (release : release_summary) =
  `Assoc
    [
      ("release_id", `String release.release_id);
      ("environment_id", `String release.environment_id);
      ("environment_name", `String release.environment_name);
      ("status", `String (release_state_to_string release.status));
      ("deployment_plan", deployment_plan_summary_to_json release.plan);
      ("image_refs", `List (List.map image_ref_to_json release.image_refs));
      ("services", `List (List.map affected_service_to_json release.services));
    ]

let rendered_manifest_to_json manifest =
  `Assoc
    [
      ("name", `String manifest.name);
      ("namespace", `String manifest.namespace);
      ("kind", `String manifest.kind);
      ("yaml", `String manifest.yaml);
    ]

let diagnostic_event_to_json event =
  `Assoc
    [
      ("source", `String event.source);
      ("reason", `String event.reason);
      ("message", `String event.message);
      ("severity", `String event.severity);
    ]

let diagnostics_to_json diagnostics =
  let optional_failure =
    match diagnostics.raw_failure_details with
    | None -> []
    | Some details -> [ ("raw_failure_details", `String details) ]
  in
  `Assoc
    ([
       ("release", release_summary_to_json diagnostics.release);
       ( "rendered_manifests",
         `List
           (List.map rendered_manifest_to_json diagnostics.rendered_manifests)
       );
       ( "reconciliation_events",
         `List
           (List.map diagnostic_event_to_json diagnostics.reconciliation_events)
       );
       ( "rollout_resources",
         `List
           (List.map (fun name -> `String name) diagnostics.rollout_resources)
       );
       ( "kubernetes_events",
         `List (List.map diagnostic_event_to_json diagnostics.kubernetes_events)
       );
     ]
    @ optional_failure)
