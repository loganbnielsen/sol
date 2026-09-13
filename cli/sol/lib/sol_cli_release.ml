(* The release record (DEC-018, FEAT-067; content-addressed by FEAT-069).

   A release record describes *what is running* — the resolved released state —
   and is named by the content-addressed release id (FEAT-069). Two deploys of
   identical content are one release with one record; the invocation is a
   deployment event (FEAT-070), whose provenance deliberately does not appear
   here, because a timestamp or commit in the artifact would churn the GitOps
   diff for an unchanged release.

   The record body is the content the id is derived from, so a reader can
   recompute the id from the record rather than trust its name (see [validate]).
   It never stores secret *values*; only the secret references a workload uses.
   Config values are part of released state and are stored, because the id is
   derived from them. *)

type workload =
  { domain : string
  ; name : string
  ; primitive : string
  ; image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; schedule : string option
  ; replicas : int
  ; cpu : string
  ; memory : string
  ; extra_labels : (string * string) list
  }

type t =
  { release_id : string
  ; workspace : string
  ; environment : string option
  ; workloads : workload list
  }

(* Label/annotation *values* are constrained (<=63 chars, no '/'); the exact
   text is preserved in the record body, this is only for lookup. *)
let sanitize_label (s : string) : string =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
       match c with
       | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> Buffer.add_char buf c
       | 'A' .. 'Z' -> Buffer.add_char buf (Char.lowercase_ascii c)
       | _ -> Buffer.add_char buf '-')
    s;
  let out = Buffer.contents buf in
  let out = if String.length out > 63 then String.sub out 0 63 else out in
  (* Trim leading/trailing separators so the label stays valid. *)
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

(* BUG-025: the pointer's name embeds the workspace, so it must go through the
   *name* sanitizer (not the label one) — '_' is fine in a label value and not
   in an object name. The shared home is [Sol_cli_kubernetes_name]. *)
let current_configmap_name ~(workspace : string) : string =
  Printf.sprintf
    "sol-release-current-%s"
    (Sol_cli_kubernetes_name.sanitize_name workspace)
;;

(* ── building the canonical record ───────────────────────────────────────── *)

let primitive_to_string (p : Sol_cli_deployment_plan.primitive) =
  match p with
  | Sol_cli_deployment_plan.Svc -> "svc"
  | Sol_cli_deployment_plan.Worker -> "worker"
  | Sol_cli_deployment_plan.Fn -> "fn"
;;

(* This mirrors the private projection in [Sol_cli_deployment_plan]'s
   [of_services_result]. It is intentionally the *same* set of facts, so
   [derived_release_id] on a record built here reproduces [plan.release_id];
   the test [of_plan rederives the plan's identity] pins the two together. *)
let workload_of_spec (spec : Sol_cli_deployment_plan.service_spec) : workload =
  { domain = spec.domain
  ; name = spec.source_name
  ; primitive = primitive_to_string spec.primitive
  ; image = spec.image
  ; config = spec.config
  ; secrets = spec.secrets
  ; schedule = spec.schedule
  ; replicas = spec.replicas
  ; cpu = Sol_cli_toml.cpu_quantity_to_string spec.cpu
  ; memory = Sol_cli_toml.memory_quantity_to_string spec.memory
  ; extra_labels = spec.extra_labels
  }
;;

let of_plan (plan : Sol_cli_deployment_plan.t) : t =
  { release_id = Sol_cli_release_id.to_string plan.release_id
  ; workspace = plan.workspace
  ; environment = plan.environment.Sol_cli_deployment_plan.env
  ; workloads = List.map workload_of_spec plan.services
  }
;;

let content_of_record (t : t) : Sol_cli_release_id.content =
  { workspace = t.workspace
  ; environment = t.environment
  ; workloads =
      List.map
        (fun (w : workload) ->
           { Sol_cli_release_id.domain = w.domain
           ; name = w.name
           ; primitive = w.primitive
           ; image = w.image
           ; config = w.config
           ; secrets = w.secrets
           ; schedule = w.schedule
           ; replicas = w.replicas
           ; cpu = w.cpu
           ; memory = w.memory
           ; extra_labels = w.extra_labels
           })
        t.workloads
  }
;;

let derived_release_id (t : t) : Sol_cli_release_id.t =
  Sol_cli_release_id.of_content (content_of_record t)
;;

let validate ~(name : string) (t : t) : (unit, string) result =
  match Sol_cli_release_id.of_string t.release_id with
  | Error msg -> Error msg
  | Ok id ->
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

(* ── JSON ─────────────────────────────────────────────────────────────────── *)

(* Ordering is not semantic: sort every map-like list so the same content
   serializes to the same bytes, which is what makes the bundle idempotent. *)
let sorted_pairs pairs = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs

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
    ; "replicas", `Int w.replicas
    ; "cpu", `String w.cpu
    ; "memory", `String w.memory
    ; "extra_labels", pairs_to_assoc w.extra_labels
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
    ]
;;

(* Safe accessors: a malformed cluster object must not crash a read-only list. *)
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
    List.map
      (fun (k, v) ->
         ( k
         , match v with
           | `String s -> s
           | _ -> "" ))
      kvs
  | _ -> []
;;

let workload_of_json (json : Yojson.Safe.t) : workload =
  { domain = str "domain" json
  ; name = str "name" json
  ; primitive = str "primitive" json
  ; image = str "image" json
  ; config = pairs "config" json
  ; secrets = pairs "secrets" json
  ; schedule = string_option "schedule" json
  ; replicas = int "replicas" json
  ; cpu = str "cpu" json
  ; memory = str "memory" json
  ; extra_labels = pairs "extra_labels" json
  }
;;

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match str "release_id" json, str "workspace" json with
  | "", _ | _, "" -> Error "release record is missing release_id/workspace"
  | release_id, workspace ->
    Ok
      { release_id
      ; workspace
      ; environment = string_option "environment" json
      ; workloads = List.map workload_of_json (list "workloads" json)
      }
;;

(* ── Kubernetes objects ───────────────────────────────────────────────────── *)

(* Applied through kubectl, which accepts JSON as YAML. [immutable: true] is
   what makes the record a record: a second apply of the same content is a
   no-op, but editing it in place is rejected by the API server. *)
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
              ; "record", `String (Yojson.Safe.to_string (to_json t))
              ] )
        ])
;;

(* Mutable pointer: names the current release per workspace, so a later
   rollback can find "what is deployed" without scanning. Its payload is
   deliberately [release_id] only — the immutable record is the one
   authoritative description, and a second copy here could drift from it. *)
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

(* ── Reading back ─────────────────────────────────────────────────────────── *)

let item_name item =
  match mem "metadata" item with
  | Some metadata -> str "name" metadata
  | None -> ""
;;

(* [kubectl get configmap -l ... -o json] -> the records it carries. An item
   whose [data.record] is absent or malformed is skipped rather than failing
   the whole listing; one that is present but does not validate is corruption,
   and is likewise not surfaced as a usable record (see [validate]). *)
let parse_kubectl_list (json : Yojson.Safe.t) : (t list, string) result =
  let items = list "items" json in
  let records =
    List.filter_map
      (fun item ->
         match mem "data" item with
         | None -> None
         | Some data ->
           (match mem "record" data with
            | Some (`String record) ->
              (try
                 match of_json (Yojson.Safe.from_string record) with
                 | Ok r ->
                   (match validate ~name:(item_name item) r with
                    | Ok () -> Some r
                    | Error _ -> None)
                 | Error _ -> None
               with
               | _ -> None)
            | _ -> None))
      items
  in
  Ok records
;;

let format_table (records : t list) : string =
  let sorted =
    List.sort (fun (a : t) (b : t) -> String.compare a.release_id b.release_id) records
  in
  let rows =
    List.map
      (fun (r : t) ->
         [ r.release_id
         ; (match r.environment with
            | None -> "-"
            | Some e -> e)
         ; string_of_int (List.length r.workloads)
         ])
      sorted
  in
  let headers = [ "ID"; "ENV"; "WORKLOADS" ] in
  let widths =
    List.mapi
      (fun i h ->
         List.fold_left
           (fun acc row -> max acc (String.length (List.nth row i)))
           (String.length h)
           rows)
      headers
  in
  let render_row row =
    List.mapi (fun i cell -> Printf.sprintf "%-*s" (List.nth widths i) cell) row
    |> String.concat "  "
    |> fun s -> String.trim s
  in
  String.concat "\n" (render_row headers :: List.map render_row rows)
;;
