type scope =
  { namespace : string
  ; workloads : string list
  }

type workload_kind =
  | Deployment
  | CronJob
  | Job
  | Rollout

let kinds = [ Deployment; CronJob; Job; Rollout ]
let selector ~workspace = "workspace=" ^ workspace
let pod_template_labels = [ "spec"; "template"; "metadata"; "labels" ]
let job_template_prefix = [ "spec"; "jobTemplate" ]

let resource_of_kind = function
  | Deployment -> "deployment"
  | CronJob -> "cronjob"
  | Job -> "job"
  | Rollout -> "rollout"
;;

let optional_kind = function
  | Rollout -> true
  | Deployment | CronJob | Job -> false
;;

let list_args ~namespace ~kind =
  [ "get"; resource_of_kind kind; "-n"; namespace; "--output"; "json" ]
;;

type release_failure =
  { namespace : string
  ; kind : string option
  ; operation : string
  ; reason : string
  }

type release =
  | Workloads_released
  | Workloads_not_releasable of string
  | Workloads_unestablished of release_failure

let failure_to_string failure =
  match failure.kind with
  | Some kind ->
    Printf.sprintf
      "in namespace %s, %s the %s failed: %s"
      failure.namespace
      failure.operation
      kind
      failure.reason
  | None ->
    Printf.sprintf
      "in namespace %s, %s failed: %s"
      failure.namespace
      failure.operation
      failure.reason
;;

let delete_args ~namespace ~names ~timeout_seconds =
  [ "delete" ]
  @ names
  @ [ "-n"
    ; namespace
    ; "--ignore-not-found"
    ; "--wait=true"
    ; Printf.sprintf "--timeout=%ds" timeout_seconds
    ]
;;

let wait_args ~namespace ~workspace ~timeout_seconds =
  [ "wait"
  ; "--for=delete"
  ; "pod"
  ; "-n"
  ; namespace
  ; "--selector"
  ; selector ~workspace
  ; Printf.sprintf "--timeout=%ds" timeout_seconds
  ]
;;

let kind_of_name = function
  | "Deployment" -> Some Deployment
  | "CronJob" -> Some CronJob
  | "Job" -> Some Job
  | "Rollout" -> Some Rollout
  | _ -> None
;;

let template_labels_of_kind = function
  | Deployment | Job | Rollout -> pod_template_labels
  | CronJob -> job_template_prefix @ pod_template_labels
;;

let template_carries_workspace ~kind ~workspace item =
  Sol_cli_json.field (template_labels_of_kind kind @ [ "workspace" ]) item
  |> Sol_cli_json.string
  = Some workspace
;;

let workload_of_item ~workspace item =
  let kind =
    Option.bind (Sol_cli_json.field [ "kind" ] item |> Sol_cli_json.string) kind_of_name
  in
  let name = Sol_cli_json.field [ "metadata"; "name" ] item |> Sol_cli_json.string in
  match kind, name with
  | Some kind, Some name when not (Sol_cli_string.is_blank name) ->
    if template_carries_workspace ~kind ~workspace item
    then Some (Printf.sprintf "%s/%s" (resource_of_kind kind) name)
    else None
  | _ -> None
;;

let workloads_of_json json ~workspace =
  match Sol_cli_json.items ~what:"the workload listing" json with
  | Error message -> Error message
  | Ok items ->
    Ok
      (items
       |> List.filter_map (workload_of_item ~workspace)
       |> List.sort_uniq String.compare)
;;

type read_error =
  | No_cluster of string
  | Read_unestablished of release_failure

let read_workloads ~run ~namespaces ~workspace : (scope list, read_error) result =
  let read_namespace ~contacted namespace =
    let rec read_kind ~contacted found = function
      | [] -> Ok (contacted, List.concat (List.rev found))
      | kind :: rest ->
        let resource = resource_of_kind kind in
        let unestablished operation reason =
          Error
            (Read_unestablished { namespace; kind = Some resource; operation; reason })
        in
        (match run (list_args ~namespace ~kind) with
         | Ok json ->
           (match workloads_of_json json ~workspace with
            | Ok workloads -> read_kind ~contacted:true (workloads :: found) rest
            | Error reason -> unestablished "reading" reason)
         | Error e ->
           let reason = Sol_cli_process.error_to_string e in
           (match Sol_cli_kubectl.classify e with
            | Sol_cli_kubectl.No_resource_type when optional_kind kind ->
              read_kind ~contacted:true found rest
            | Sol_cli_kubectl.Not_found -> read_kind ~contacted:true found rest
            | Sol_cli_kubectl.Unreachable when not contacted ->
              Error
                (No_cluster
                   (Printf.sprintf "the cluster could not be reached (%s)" reason))
            | _ -> unestablished "reading" reason))
    in
    Result.map
      (fun (contacted, workloads) -> contacted, { namespace; workloads })
      (read_kind ~contacted [] kinds)
  in
  let rec go ~contacted scopes = function
    | [] -> Ok (List.rev scopes)
    | namespace :: rest ->
      (match read_namespace ~contacted namespace with
       | Ok (contacted, scope) -> go ~contacted (scope :: scopes) rest
       | Error error -> Error error)
  in
  go ~contacted:false [] namespaces
;;

let to_string scope =
  match scope.workloads with
  | [] -> Printf.sprintf "%s: no workload of this workspace is running" scope.namespace
  | workloads ->
    Printf.sprintf "%s: releasing %s" scope.namespace (String.concat ", " workloads)
;;
