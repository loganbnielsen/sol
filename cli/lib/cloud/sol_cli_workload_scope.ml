type scope =
  { namespace : string
  ; pods : string list
  }

let selector ~workspace = "workspace=" ^ workspace

let list_args ~namespace ~workspace =
  [ "get"
  ; "pods"
  ; "-n"
  ; namespace
  ; "--selector"
  ; selector ~workspace
  ; "--output"
  ; "json"
  ]
;;

let delete_args ~namespace ~workspace ~timeout_seconds =
  [ "delete"
  ; "deployment,cronjob,job"
  ; "-n"
  ; namespace
  ; "--selector"
  ; selector ~workspace
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

let pods_of_pods_json json =
  match Sol_cli_json.items ~what:"the pod listing" json with
  | Error message -> Error message
  | Ok items ->
    Ok
      (items
       |> List.filter_map (fun item ->
         Sol_cli_json.field [ "metadata"; "name" ] item |> Sol_cli_json.string)
       |> List.sort String.compare)
;;

let to_string scope =
  match scope.pods with
  | [] -> Printf.sprintf "%s: no workload of this workspace is running" scope.namespace
  | pods ->
    Printf.sprintf "%s: releasing %s" scope.namespace (String.concat ", " pods)
;;
