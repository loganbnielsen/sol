type workload = Sol_cli_release_id.workload

type apply_mode =
  | Direct
  | Gitops

let apply_mode_to_string = function
  | Direct -> "direct"
  | Gitops -> "gitops"
;;

let apply_mode_of_string = function
  | "direct" -> Ok Direct
  | "gitops" -> Ok Gitops
  | s ->
    Error
      (Printf.sprintf
         "%S is not a valid apply_mode (expected \"direct\" or \"gitops\")"
         s)
;;

type t =
  { release_id : string
  ; workspace : string
  ; environment : string option
  ; workloads : workload list
  ; migrations : string list
  ; apply_mode : apply_mode
  }

let sanitize_label (s : string) : string =
  let buf = Buffer.create (String.length s) in
  s
  |> String.iter (fun c ->
    match c with
    | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> Buffer.add_char buf c
    | 'A' .. 'Z' -> Buffer.add_char buf (Char.lowercase_ascii c)
    | _ -> Buffer.add_char buf '-');
  let out = Buffer.contents buf in
  let out = if String.length out > 63 then String.sub out 0 63 else out in
  let len = String.length out in
  let start = ref 0 in
  while
    !start < len && (out.[!start] = '-' || out.[!start] = '.' || out.[!start] = '_')
  do
    incr start
  done;
  let stop = ref (len - 1) in
  while
    !stop >= !start && (out.[!stop] = '-' || out.[!stop] = '.' || out.[!stop] = '_')
  do
    decr stop
  done;
  let trimmed =
    if !stop < !start then "" else String.sub out !start (!stop - !start + 1)
  in
  if trimmed = "" then "none" else trimmed
;;

let configmap_name (t : t) : string = Printf.sprintf "sol-release-%s" t.release_id

let current_configmap_name ~(workspace : string) : string =
  Printf.sprintf
    "sol-release-current-%s"
    (Sol_cli_kubernetes_name.sanitize_name workspace)
;;

let workload_of_spec (spec : Sol_cli_deployment_plan.service_spec) : workload =
  Sol_cli_deployment_plan.release_workload_of_spec spec
;;

let of_plan ~(apply_mode : apply_mode) (plan : Sol_cli_deployment_plan.t) : t =
  { release_id = Sol_cli_release_id.to_string plan.release_id
  ; workspace = plan.workspace
  ; environment = plan.environment.env
  ; workloads = List.map workload_of_spec plan.services
  ; migrations = List.map Sol_cli_plan_ids.Migration_file.to_string plan.migrations
  ; apply_mode
  }
;;

let content_of_record (t : t) : Sol_cli_release_id.content =
  { workspace = t.workspace; environment = t.environment; workloads = t.workloads }
;;

let derived_release_id (t : t) : Sol_cli_release_id.t =
  Sol_cli_release_id.of_content (content_of_record t)
;;

let validate ~(name : string) (t : t) : (unit, string) result =
  let open Result.Syntax in
  let* id = Sol_cli_release_id.of_string t.release_id in
  if not (String.equal name (configmap_name t))
  then
    Error
      (Printf.sprintf
         "%s is not the record for release %s (expected name %s)"
         name
         t.release_id
         (configmap_name t))
  else (
    let derived = derived_release_id t in
    if derived <> id
    then
      Error
        (Printf.sprintf
           "release record %s is corrupt: its content rederives %s"
           t.release_id
           (Sol_cli_release_id.to_string derived))
    else Ok ())
;;

let sorted_pairs pairs =
  pairs
  |> List.sort (fun (a, av) (b, bv) ->
    let by_key = String.compare a b in
    if by_key <> 0 then by_key else String.compare av bv)
;;

let pairs_to_assoc pairs =
  `Assoc (List.map (fun (k, v) -> k, `String v) (sorted_pairs pairs))
;;

let compare_workload (a : workload) (b : workload) =
  let by_domain = String.compare a.domain b.domain in
  if by_domain <> 0
  then by_domain
  else (
    let by_name = String.compare a.name b.name in
    if by_name <> 0 then by_name else String.compare a.primitive b.primitive)
;;

let compare_row4 (a1, a2, a3, a4) (b1, b2, b3, b4) =
  let c = String.compare a1 b1 in
  if c <> 0
  then c
  else (
    let c = String.compare a2 b2 in
    if c <> 0
    then c
    else (
      let c = String.compare a3 b3 in
      if c <> 0 then c else String.compare a4 b4))
;;

let rows_to_json rows =
  `List
    (List.sort compare_row4 rows
     |> List.map (fun (a, b, c, d) ->
       `List [ `String a; `String b; `String c; `String d ]))
;;

let workload_to_json (w : workload) : Yojson.Safe.t =
  `Assoc
    [ "domain", `String w.domain
    ; "name", `String w.name
    ; "primitive", `String w.primitive
    ; "image", `String w.image
    ; "config", pairs_to_assoc w.config
    ; "secrets", pairs_to_assoc w.secrets
    ; ( "schedule"
      , match w.schedule with
        | None -> `Null
        | Some s -> `String s )
    ; "scheduled_concurrency", `String w.scheduled_concurrency
    ; "backoff_limit", `Int w.backoff_limit
    ; "replicas", `Int w.replicas
    ; "availability", `String w.availability
    ; "consumes_kafka", `Bool w.consumes_kafka
    ; "cpu", `String w.cpu
    ; "memory", `String w.memory
    ; "extra_labels", pairs_to_assoc w.extra_labels
    ; "volumes", rows_to_json w.volumes
    ; "rollout", `String w.rollout
    ; ( "ingress_host"
      , match w.ingress_host with
        | None -> `Null
        | Some h -> `String h )
    ; ( "ingress_path"
      , match w.ingress_path with
        | None -> `Null
        | Some p -> `String p )
    ; "cluster_issuer", `String w.cluster_issuer
    ; "calls", rows_to_json w.calls
    ]
;;

let to_json (t : t) : Yojson.Safe.t =
  `Assoc
    [ "release_id", `String t.release_id
    ; "workspace", `String t.workspace
    ; ( "environment"
      , match t.environment with
        | None -> `Null
        | Some e -> `String e )
    ; ( "workloads"
      , `List (List.map workload_to_json (List.sort compare_workload t.workloads)) )
    ; ( "migrations"
      , `List (List.map (fun m -> `String m) (List.sort String.compare t.migrations)) )
    ; "apply_mode", `String (apply_mode_to_string t.apply_mode)
    ]
;;

let record_json_string (t : t) : string = Yojson.Safe.to_string (to_json t)
let record_digest (t : t) : string = Digest.to_hex (Digest.string (record_json_string t))

let mem key = function
  | `Assoc kvs -> List.assoc_opt key kvs
  | _ -> None
;;

let str key json =
  match mem key json with
  | Some (`String s) -> s
  | _ -> ""
;;

let int key json =
  match mem key json with
  | Some (`Int i) -> i
  | _ -> 0
;;

let list key json =
  match mem key json with
  | Some (`List l) -> l
  | _ -> []
;;

let string_option key json =
  match mem key json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let pairs key json =
  match mem key json with
  | Some (`Assoc kvs) ->
    kvs
    |> List.map (fun (k, v) ->
      ( k
      , match v with
        | `String s -> s
        | _ -> "" ))
  | _ -> []
;;

let rows key json =
  match mem key json with
  | Some (`List rows) ->
    List.map
      (function
        | `List cells ->
          List.map
            (function
              | `String s -> s
              | _ -> "")
            cells
        | _ -> [])
      rows
  | _ -> []
;;

let row4 = function
  | [ a; b; c; d ] -> a, b, c, d
  | _ -> "", "", "", ""
;;

let workload_of_json (json : Yojson.Safe.t) : workload =
  { domain = str "domain" json
  ; name = str "name" json
  ; primitive = str "primitive" json
  ; image = str "image" json
  ; config = pairs "config" json
  ; secrets = pairs "secrets" json
  ; schedule = string_option "schedule" json
  ; scheduled_concurrency = str "scheduled_concurrency" json
  ; backoff_limit = int "backoff_limit" json
  ; replicas = int "replicas" json
  ; availability =
      (match Sol_cli_json.field [ "availability" ] json with
       | `String s -> s
       | _ -> "single")
  ; consumes_kafka =
      (match Sol_cli_json.field [ "consumes_kafka" ] json with
       | `Bool b -> b
       | _ -> false)
  ; cpu = str "cpu" json
  ; memory = str "memory" json
  ; extra_labels = pairs "extra_labels" json
  ; volumes = List.map row4 (rows "volumes" json)
  ; rollout = str "rollout" json
  ; ingress_host = string_option "ingress_host" json
  ; ingress_path = string_option "ingress_path" json
  ; cluster_issuer = str "cluster_issuer" json
  ; calls = List.map row4 (rows "calls" json)
  }
;;

let string_list key json =
  List.filter_map
    (function
      | `String s -> Some s
      | _ -> None)
    (list key json)
;;

let apply_mode_of_json (json : Yojson.Safe.t) : (apply_mode, string) result =
  match mem "apply_mode" json with
  | Some (`String s) -> apply_mode_of_string s
  | Some _ -> Error "release record has a non-string apply_mode"
  | None -> Error "release record is missing apply_mode"
;;

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match str "release_id" json, str "workspace" json with
  | "", _ | _, "" -> Error "release record is missing release_id/workspace"
  | release_id, workspace ->
    let open Result.Syntax in
    let* apply_mode = apply_mode_of_json json in
    Ok
      { release_id
      ; workspace
      ; environment = string_option "environment" json
      ; workloads = List.map workload_of_json (list "workloads" json)
      ; migrations = string_list "migrations" json
      ; apply_mode
      }
;;

let to_configmap_json (t : t) : string =
  Yojson.Safe.pretty_to_string
    (`Assoc
        [ "apiVersion", `String "v1"
        ; "kind", `String "ConfigMap"
        ; "immutable", `Bool true
        ; ( "metadata"
          , `Assoc
              [ "name", `String (configmap_name t)
              ; "namespace", `String "default"
              ; ( "labels"
                , `Assoc
                    [ "sol.dev/type", `String "release"
                    ; "sol.dev/workspace", `String (sanitize_label t.workspace)
                    ] )
              ] )
        ; ( "data"
          , `Assoc
              [ "release_id", `String t.release_id
              ; "record", `String (record_json_string t)
              ; "record_digest", `String (record_digest t)
              ] )
        ])
;;

let to_current_configmap_json (t : t) : string =
  Yojson.Safe.pretty_to_string
    (`Assoc
        [ "apiVersion", `String "v1"
        ; "kind", `String "ConfigMap"
        ; ( "metadata"
          , `Assoc
              [ "name", `String (current_configmap_name ~workspace:t.workspace)
              ; "namespace", `String "default"
              ; ( "labels"
                , `Assoc
                    [ "sol.dev/type", `String "release-current"
                    ; "sol.dev/workspace", `String (sanitize_label t.workspace)
                    ] )
              ] )
        ; "data", `Assoc [ "release_id", `String t.release_id ]
        ])
;;

let bundle_files (t : t) : (string * string) list =
  [ configmap_name t ^ ".yaml", to_configmap_json t
  ; "sol-current-release.yaml", to_current_configmap_json t
  ]
;;

let item_name item =
  match mem "metadata" item with
  | Some metadata -> str "name" metadata
  | None -> ""
;;

let creation_timestamp_of_item ~label item =
  Sol_cli_json.require
    ~what:label
    [ "metadata"; "creationTimestamp" ]
    Sol_cli_json.string
    item
;;

let of_kubectl_item (item : Yojson.Safe.t) : (t, string) result =
  let name = item_name item in
  let label = if String.equal name "" then "<unnamed configmap>" else name in
  match mem "data" item with
  | None -> Error (Printf.sprintf "%s has no data" label)
  | Some data ->
    (match mem "record" data with
     | Some (`String record) ->
       (match mem "record_digest" data with
        | Some (`String stored) when String.length stored > 0 ->
          if not (String.equal (Digest.to_hex (Digest.string record)) stored)
          then Error (Printf.sprintf "%s failed integrity validation" label)
          else
            let open Result.Syntax in
            let* parsed = Sol_cli_json.decode ~what:(label ^ ": data.record") record in
            let* r = of_json parsed |> Result.map_error (Printf.sprintf "%s: %s" label) in
            let* () = validate ~name r in
            Ok r
        | _ ->
          Error
            (Printf.sprintf
               "%s uses an unsupported record format: missing integrity digest"
               label))
     | _ -> Error (Printf.sprintf "%s has no data.record" label))
;;

let list_items json =
  Sol_cli_json.require ~what:"release list" [ "items" ] Sol_cli_json.list json
;;

let record_of_item item =
  of_kubectl_item item
  |> Result.map_error (Printf.sprintf "release history contains an invalid record: %s")
;;

let parse_kubectl_list_with_creation (json : Yojson.Safe.t)
  : ((t * string) list, string) result
  =
  let open Result.Syntax in
  let with_creation item =
    let* record = record_of_item item in
    let* created = creation_timestamp_of_item ~label:(item_name item) item in
    Ok (record, created)
  in
  let* items = list_items json in
  Sol_cli_result.map_list with_creation items
;;

let parse_kubectl_list json =
  let open Result.Syntax in
  let* items = list_items json in
  Sol_cli_result.map_list record_of_item items
;;

let format_table (records : t list) : string =
  let sorted = List.sort (fun a b -> String.compare a.release_id b.release_id) records in
  let rows =
    sorted
    |> List.map (fun r ->
      [ r.release_id
      ; (match r.environment with
         | None -> "-"
         | Some e -> e)
      ; string_of_int (List.length r.workloads)
      ])
  in
  let headers = [ "ID"; "ENV"; "WORKLOADS" ] in
  let widths =
    headers
    |> List.mapi (fun i h ->
      List.fold_left
        (fun acc row -> max acc (String.length (List.nth row i)))
        (String.length h)
        rows)
  in
  let render_row row =
    List.mapi (fun i cell -> Printf.sprintf "%-*s" (List.nth widths i) cell) row
    |> String.concat "  "
    |> fun s -> String.trim s
  in
  String.concat "\n" (render_row headers :: List.map render_row rows)
;;

let finish_deployment ~(record_release : unit -> (unit, string) result) ~report_success =
  let open Result.Syntax in
  let* () = record_release () in
  report_success ();
  Ok ()
;;
