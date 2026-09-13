(* The release record (DEC-018, FEAT-067): what was deployed, from what, and how
   it was scoped — recorded immutably in the target's cluster so a later
   rollback can restore it and an operator can audit it.

   Never stores secret *values*; only the key names, because the record is meant
   to be readable by anyone with cluster access. *)

type workload =
  { domain : string
  ; name : string
  ; image : string
  ; config_keys : string list
  ; secret_keys : string list
  }

type t =
  { release_id : string
  ; created_at : string
  ; workspace : string
  ; target : string
  ; mode : string
  ; git_commit : string
  ; git_dirty : bool
  ; requested_scope : string
  ; workloads : workload list
  ; migrations : string list
  }

(* UTC, second precision, lexicographically sortable. *)
let rfc3339_utc (now : float) : string =
  let tm = Unix.gmtime now in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
;;

(* DNS-1123-ish, lowercase: the release id becomes part of a ConfigMap name. *)
let generate_release_id ~(now : float) ~(commit : string) : string =
  let tm = Unix.gmtime now in
  Printf.sprintf
    "%04d%02d%02dt%02d%02d%02dz-%s"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
    (String.lowercase_ascii commit)
;;

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

let of_plan
      ~(workspace : string)
      ~(target : string)
      ~(mode : string)
      ~(git_commit : string)
      ~(git_dirty : bool)
      (plan : Sol_cli_deployment_plan.t)
  : t
  =
  let now = Unix.gettimeofday () in
  let workloads =
    List.map
      (fun (spec : Sol_cli_deployment_plan.service_spec) ->
         { domain = spec.domain
         ; name = spec.source_name
         ; image = spec.image
         ; config_keys = List.map fst spec.config
         ; secret_keys = List.map fst spec.secrets
         })
      plan.Sol_cli_deployment_plan.services
  in
  let migrations =
    List.map
      Sol_cli_plan_ids.Migration_file.to_string
      plan.Sol_cli_deployment_plan.migrations
  in
  { release_id = generate_release_id ~now ~commit:git_commit
  ; created_at = rfc3339_utc now
  ; workspace
  ; target
  ; mode
  ; git_commit
  ; git_dirty
  ; requested_scope = plan.Sol_cli_deployment_plan.requested_scope
  ; workloads
  ; migrations
  }
;;

(* ── JSON ─────────────────────────────────────────────────────────────────── *)

let json_string s = `String s
let json_list f xs = `List (List.map f xs)

let workload_to_json (w : workload) : Yojson.Safe.t =
  `Assoc
    [ "domain", `String w.domain
    ; "name", `String w.name
    ; "image", `String w.image
    ; "config_keys", json_list json_string w.config_keys
    ; "secret_keys", json_list json_string w.secret_keys
    ]
;;

let to_json (t : t) : Yojson.Safe.t =
  `Assoc
    [ "release_id", `String t.release_id
    ; "created_at", `String t.created_at
    ; "workspace", `String t.workspace
    ; "target", `String t.target
    ; "mode", `String t.mode
    ; "git_commit", `String t.git_commit
    ; "git_dirty", `Bool t.git_dirty
    ; "requested_scope", `String t.requested_scope
    ; "workloads", json_list workload_to_json t.workloads
    ; "migrations", json_list json_string t.migrations
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

let boolean key json =
  match mem key json with
  | Some (`Bool b) -> b
  | _ -> false
;;

let list key json =
  match mem key json with
  | Some (`List l) -> l
  | _ -> []
;;

let str_list key json =
  List.map
    (function
      | `String s -> s
      | _ -> "")
    (list key json)
;;

let workload_of_json json : workload =
  { domain = str "domain" json
  ; name = str "name" json
  ; image = str "image" json
  ; config_keys = str_list "config_keys" json
  ; secret_keys = str_list "secret_keys" json
  }
;;

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match str "release_id" json, str "created_at" json with
  | "", _ | _, "" -> Error "release record is missing release_id/created_at"
  | release_id, created_at ->
    Ok
      { release_id
      ; created_at
      ; workspace = str "workspace" json
      ; target = str "target" json
      ; mode = str "mode" json
      ; git_commit = str "git_commit" json
      ; git_dirty = boolean "git_dirty" json
      ; requested_scope = str "requested_scope" json
      ; workloads = List.map workload_of_json (list "workloads" json)
      ; migrations = str_list "migrations" json
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
                    ; "sol.dev/target", `String (sanitize_label t.target)
                    ; "sol.dev/scope", `String (sanitize_label t.requested_scope)
                    ; "sol.dev/git-commit", `String (sanitize_label t.git_commit)
                    ] )
              ; ( "annotations"
                , `Assoc
                    [ "sol.dev/created-at", `String t.created_at
                    ; "sol.dev/mode", `String t.mode
                    ; "sol.dev/git-dirty", `String (string_of_bool t.git_dirty)
                    ] )
              ] )
        ; ( "data"
          , `Assoc
              [ "release_id", `String t.release_id
              ; "requested_scope", `String t.requested_scope
              ; "record", `String (Yojson.Safe.to_string (to_json t))
              ] )
        ])
;;

(* Mutable pointer: names the current release per workspace, so a later
   rollback can find "what is deployed" without scanning. *)
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
        ; ( "data"
          , `Assoc
              [ "release_id", `String t.release_id
              ; "target", `String t.target
              ; "requested_scope", `String t.requested_scope
              ; "updated_at", `String t.created_at
              ] )
        ])
;;

(* ── Reading back ─────────────────────────────────────────────────────────── *)

(* [kubectl get configmap -l ... -o json] -> the records it carries. An item
   whose [data.record] is absent or malformed is skipped rather than failing
   the whole listing. *)
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
              (try of_json (Yojson.Safe.from_string record) |> Result.to_option with
               | _ -> None)
            | _ -> None))
      items
  in
  Ok records
;;

let format_table (records : t list) : string =
  let sorted =
    List.sort (fun (a : t) (b : t) -> compare b.created_at a.created_at) records
  in
  let rows =
    List.map
      (fun (r : t) ->
         [ r.release_id; r.git_commit; r.requested_scope; r.created_at; r.target ])
      sorted
  in
  let headers = [ "ID"; "COMMIT"; "SCOPE"; "CREATED"; "TARGET" ] in
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

(* ── Provenance ───────────────────────────────────────────────────────────── *)

let run_git args =
  match Sol_cli_process.run (Sol_cli_process.cmd ("git" :: args)) with
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    Some (String.trim r.Sol_cli_process.stdout)
  | _ -> None
;;

let git_commit () =
  match run_git [ "rev-parse"; "--short"; "HEAD" ] with
  | Some s when s <> "" -> s
  | _ -> "unknown"
;;

let git_dirty () =
  match run_git [ "status"; "--porcelain" ] with
  | Some s -> s <> ""
  | None -> false
;;
