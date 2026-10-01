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

let delete_args ~namespace ~names ~timeout_seconds =
  [ "delete" ]
  @ names
  @ [ "-n"; namespace; "--wait=true"; Printf.sprintf "--timeout=%ds" timeout_seconds ]
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

let to_string scope =
  match scope.workloads with
  | [] -> Printf.sprintf "%s: no workload of this workspace is running" scope.namespace
  | workloads ->
    Printf.sprintf "%s: releasing %s" scope.namespace (String.concat ", " workloads)
;;
