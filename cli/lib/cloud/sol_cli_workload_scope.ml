type scope = { namespaces : string list }

let selector ~workspace = "workspace=" ^ workspace

let list_args ~workspace =
  [ "kubectl"
  ; "get"
  ; "pods"
  ; "--all-namespaces"
  ; "--selector"
  ; selector ~workspace
  ; "--output"
  ; "json"
  ]
;;

let delete_namespace_args ~namespace ~timeout_seconds =
  [ "kubectl"
  ; "delete"
  ; "namespace"
  ; namespace
  ; "--wait=true"
  ; Printf.sprintf "--timeout=%ds" timeout_seconds
  ]
;;

let namespaces_of_pods_json json =
  match Sol_cli_json.items ~what:"the pod listing" json with
  | Error message -> Error message
  | Ok items ->
    Ok
      (items
       |> List.filter_map (fun item ->
         Sol_cli_json.field [ "metadata"; "namespace" ] item |> Sol_cli_json.string)
       |> List.filter (fun namespace -> namespace <> "")
       |> List.sort_uniq String.compare)
;;

let to_string scope =
  match scope.namespaces with
  | [] -> "no namespace holds a pod this workspace deployed"
  | namespaces ->
    Printf.sprintf
      "the namespaces holding this workspace's deployed pods are %s"
      (String.concat ", " namespaces)
;;
