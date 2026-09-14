(* The deployment event (FEAT-070, FEAT-071): one deploy *attempt*, recorded
   immutably.

   It points at the release the attempt tried to put in place (by [release_id])
   and carries the provenance around the attempt — including its [outcome]. It
   never defines a release, and provenance never enters the release artifact or
   the pod template — that is what keeps a no-op redeploy from changing the
   rendered manifests.

   The record is the authority; the Loki deploy marker carries the same
   [deployment_id] only as a join key, and is only emitted once this record has
   actually been persisted.

   Both identities stay typed here (FEAT-071): [deployment_id] and [release_id]
   are abstract ids, and [to_string]/[of_string] happen only at the JSON/YAML/
   table boundary, exactly as on the release path. *)

type outcome =
  | Applied
  | Apply_failed

type t =
  { deployment_id : Sol_cli_deployment_id.t
  ; release_id : Sol_cli_release_id.t
  ; workspace : string
  ; environment : string option
  ; created_at : string
  ; git_commit : string
  ; git_dirty : bool
  ; actor : string option
  ; target : string option
  ; mode : string
  ; requested_scope : string
  ; outcome : outcome
  }

let outcome_to_string = function
  | Applied -> "applied"
  | Apply_failed -> "apply_failed"
;;

let outcome_of_string = function
  | "applied" -> Ok Applied
  | "apply_failed" -> Ok Apply_failed
  | s ->
    Error
      (Printf.sprintf
         "%S is not a deployment outcome (expected applied or apply_failed)"
         s)
;;

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

let deployment_mode_to_string (m : Sol_cli_deployment_plan.deployment_mode) =
  match m with
  | Local -> "local"
  | Customer_cloud -> "customer_cloud"
  | Sol_hosted -> "sol_hosted"
;;

(* Invocation provenance. The release id is consumed from the plan, never
   rederived; the provenance is recorded here and nowhere on the release path. *)
let of_plan
      ~(deployment_id : Sol_cli_deployment_id.t)
      ~(now : float)
      ~(git_commit : string)
      ~(git_dirty : bool)
      ~(actor : string option)
      ~(target : string option)
      ~(outcome : outcome)
      (plan : Sol_cli_deployment_plan.t)
  : t
  =
  { deployment_id
  ; release_id = plan.Sol_cli_deployment_plan.release_id
  ; workspace = plan.Sol_cli_deployment_plan.workspace
  ; environment = plan.Sol_cli_deployment_plan.environment.Sol_cli_deployment_plan.env
  ; created_at = rfc3339_utc now
  ; git_commit
  ; git_dirty
  ; actor
  ; target
  ; mode =
      deployment_mode_to_string
        plan.Sol_cli_deployment_plan.environment.Sol_cli_deployment_plan.mode
  ; requested_scope = plan.Sol_cli_deployment_plan.requested_scope
  ; outcome
  }
;;

(* Provenance is best-effort: outside a Git checkout these are [""] and clean,
   not a failure to deploy. *)
let run_git args =
  match Sol_cli_process.run (Sol_cli_process.cmd ("git" :: args)) with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> String.trim r.Sol_cli_process.stdout
  | _ -> ""
;;

let git_commit () = run_git [ "rev-parse"; "--short"; "HEAD" ]
let git_dirty () = run_git [ "status"; "--porcelain" ] <> ""

(* The id goes in verbatim: [d-...] is lowercase RFC 1123 by construction. *)
let configmap_name (t : t) : string =
  Printf.sprintf "sol-deployment-%s" (Sol_cli_deployment_id.to_string t.deployment_id)
;;

(* FEAT-071: constructing [t] (through [of_plan] or [of_json]) already
   established both identities, so the only remaining invariant to check on the
   read path is the name direction. A correctly named record is not corrupt. *)
let validate ~(name : string) (t : t) : (unit, string) result =
  if String.equal name (configmap_name t)
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s is not the record for deployment %s (expected name %s)"
         name
         (Sol_cli_deployment_id.to_string t.deployment_id)
         (configmap_name t))
;;

(* ── JSON ─────────────────────────────────────────────────────────────────── *)

let to_json (t : t) : Yojson.Safe.t =
  `Assoc
    [ "deployment_id", `String (Sol_cli_deployment_id.to_string t.deployment_id)
    ; "release_id", `String (Sol_cli_release_id.to_string t.release_id)
    ; "workspace", `String t.workspace
    ; ( "environment"
      , match t.environment with
        | None -> `Null
        | Some e -> `String e )
    ; "created_at", `String t.created_at
    ; "git_commit", `String t.git_commit
    ; "git_dirty", `Bool t.git_dirty
    ; ( "actor"
      , match t.actor with
        | None -> `Null
        | Some a -> `String a )
    ; ( "target"
      , match t.target with
        | None -> `Null
        | Some x -> `String x )
    ; "mode", `String t.mode
    ; "requested_scope", `String t.requested_scope
    ; "outcome", `String (outcome_to_string t.outcome)
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

let bool key json =
  match mem key json with
  | Some (`Bool b) -> b
  | _ -> false
;;

let string_option key json =
  match mem key json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let list key json =
  match mem key json with
  | Some (`List l) -> l
  | _ -> []
;;

(* FEAT-071: ids are parsed here, at the boundary, and stay typed in [t]. A
   malformed id is an error, never a string that later reaches [configmap_name]
   or a label. *)
let of_json (json : Yojson.Safe.t) : (t, string) result =
  let missing field = Error (Printf.sprintf "deployment record is missing %s" field) in
  match str "deployment_id" json, str "release_id" json, str "workspace" json with
  | "", _, _ -> missing "deployment_id"
  | _, "", _ -> missing "release_id"
  | _, _, "" -> missing "workspace"
  | raw_deployment_id, raw_release_id, workspace ->
    (match Sol_cli_deployment_id.of_string raw_deployment_id with
     | Error msg -> Error (Printf.sprintf "deployment record has an invalid id: %s" msg)
     | Ok deployment_id ->
       (match Sol_cli_release_id.of_string raw_release_id with
        | Error msg ->
          Error (Printf.sprintf "deployment record has an invalid release id: %s" msg)
        | Ok release_id ->
          (match outcome_of_string (str "outcome" json) with
           | Error msg -> Error msg
           | Ok outcome ->
             Ok
               { deployment_id
               ; release_id
               ; workspace
               ; environment = string_option "environment" json
               ; created_at = str "created_at" json
               ; git_commit = str "git_commit" json
               ; git_dirty = bool "git_dirty" json
               ; actor = string_option "actor" json
               ; target = string_option "target" json
               ; mode = str "mode" json
               ; requested_scope = str "requested_scope" json
               ; outcome
               })))
;;

(* ── Kubernetes objects ───────────────────────────────────────────────────── *)

(* Applied through kubectl, which accepts JSON as YAML. [immutable: true] is what
   makes the event a record: a later failure or unhealthy rollout is never
   written back into it as a status snapshot. *)
let to_configmap_json (t : t) : string =
  let labels =
    [ "sol.dev/type", `String "deployment"
    ; "sol.dev/workspace", `String (Sol_cli_release.sanitize_label t.workspace)
    ; "sol.dev/release", `String (Sol_cli_release_id.to_string t.release_id)
    ]
    @
    match t.target with
    | None -> []
    | Some target -> [ "sol.dev/target", `String (Sol_cli_release.sanitize_label target) ]
  in
  Yojson.Safe.pretty_to_string
    (`Assoc
        [ "apiVersion", `String "v1"
        ; "kind", `String "ConfigMap"
        ; "immutable", `Bool true
        ; ( "metadata"
          , `Assoc
              [ "name", `String (configmap_name t)
              ; "namespace", `String "default"
              ; "labels", `Assoc labels
              ] )
        ; ( "data"
          , `Assoc
              [ "deployment_id", `String (Sol_cli_deployment_id.to_string t.deployment_id)
              ; "record", `String (Yojson.Safe.to_string (to_json t))
              ] )
        ])
;;

(* ── Reading back ─────────────────────────────────────────────────────────── *)

let item_name item =
  match mem "metadata" item with
  | Some metadata -> str "name" metadata
  | None -> ""
;;

(* FEAT-071: fail closed. The store is authoritative deployment history, so a
   matching ConfigMap that is unparseable, malformed, or does not validate is
   corruption — silently dropping it would print a partial history as if it were
   the whole one. The error names the record so an operator can find it. *)
let parse_kubectl_list (json : Yojson.Safe.t) : (t list, string) result =
  let corrupt label msg =
    Error
      (Printf.sprintf "deployment history contains an invalid record: %s: %s" label msg)
  in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let name = item_name item in
      let label = if String.equal name "" then "<unnamed configmap>" else name in
      (match mem "data" item with
       | None -> corrupt label "has no data"
       | Some data ->
         (match mem "record" data with
          | Some (`String record) ->
            (match Yojson.Safe.from_string record with
             | exception _ -> corrupt label "data.record is not JSON"
             | parsed ->
               (match of_json parsed with
                | Error msg -> corrupt label msg
                | Ok r ->
                  (match validate ~name r with
                   | Error msg -> corrupt label msg
                   | Ok () -> go (r :: acc) rest)))
          | _ -> corrupt label "has no data.record"))
  in
  go [] (list "items" json)
;;

(* Newest first. [created_at] is the authority; the id breaks ties (and is itself
   time-prefixed, so the two agree unless a clock moved backwards). *)
let format_table (records : t list) : string =
  let sorted =
    List.sort
      (fun (a : t) (b : t) ->
         let by_time = String.compare b.created_at a.created_at in
         if by_time <> 0
         then by_time
         else
           String.compare
             (Sol_cli_deployment_id.to_string b.deployment_id)
             (Sol_cli_deployment_id.to_string a.deployment_id))
      records
  in
  let rows =
    List.map
      (fun (r : t) ->
         [ Sol_cli_deployment_id.to_string r.deployment_id
         ; Sol_cli_release_id.to_string r.release_id
         ; r.created_at
         ; (if String.equal r.git_commit "" then "-" else r.git_commit)
         ; outcome_to_string r.outcome
         ])
      sorted
  in
  let headers = [ "DEPLOYMENT"; "RELEASE"; "TIME"; "COMMIT"; "STATUS" ] in
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
