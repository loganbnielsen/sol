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

let namespaces_of_items items =
  items
  |> List.filter_map (fun item ->
    match Yojson.Safe.Util.member "metadata" item with
    | `Assoc _ as metadata ->
      (match Yojson.Safe.Util.member "namespace" metadata with
       | `String namespace when namespace <> "" -> Some namespace
       | _ -> None)
    | _ -> None)
  |> List.sort_uniq String.compare
;;

let namespaces_of_pods_json json =
  match Yojson.Safe.from_string json with
  | `Assoc _ as document ->
    (match Yojson.Safe.Util.member "items" document with
     | `List items -> Ok (namespaces_of_items items)
     | `Null -> Ok []
     | _ ->
       Error
         "the pod listing has no items list, so the workload scope it describes is \
          unknown")
  | `Null -> Ok []
  | _ ->
    Error
      "the pod listing is not an object, so the workload scope it describes is unknown"
  | exception Yojson.Json_error message ->
    Error (Printf.sprintf "the pod listing is not valid JSON (%s)" message)
;;

let to_string scope =
  match scope.namespaces with
  | [] -> "no namespace holds a pod this workspace deployed"
  | namespaces ->
    Printf.sprintf
      "the namespaces holding this workspace's deployed pods are %s"
      (String.concat ", " namespaces)
;;
