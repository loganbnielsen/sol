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
  ; actor_source : string option
  ; target : string option
  ; mode : string
  ; requested_scope : string
  ; profile : Sol_cli_profile.t option
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

let rfc3339_utc (now : float) : string = Sol_cli_time.rfc3339 now

let deployment_mode_to_string (m : Sol_cli_deployment_plan.deployment_mode) =
  match m with
  | Local -> "local"
  | Customer_cloud -> "customer_cloud"
  | Sol_hosted -> "sol_hosted"
;;

let of_plan
      ?release_id
      ~(deployment_id : Sol_cli_deployment_id.t)
      ~(now : float)
      ~(git_commit : string)
      ~(git_dirty : bool)
      ~(actor : string option)
      ~(actor_source : string option)
      ~(target : string option)
      ~(outcome : outcome)
      (plan : Sol_cli_deployment_plan.t)
  : t
  =
  { deployment_id
  ; release_id = Option.value release_id ~default:plan.release_id
  ; workspace = plan.workspace
  ; environment = plan.environment.Sol_cli_deployment_plan.env
  ; created_at = rfc3339_utc now
  ; git_commit
  ; git_dirty
  ; actor
  ; actor_source
  ; target
  ; mode = deployment_mode_to_string plan.environment.Sol_cli_deployment_plan.mode
  ; requested_scope = plan.requested_scope
  ; profile =
      plan.profile
      |> Option.map (fun (claim : Sol_cli_deployment_plan.profile_claim) -> claim.profile)
  ; outcome
  }
;;

let run_git args =
  match Sol_cli_process.run (Sol_cli_process.cmd ("git" :: args)) with
  | Ok r -> String.trim r.stdout
  | _ -> ""
;;

let git_commit () = run_git [ "rev-parse"; "--short"; "HEAD" ]
let git_dirty () = run_git [ "status"; "--porcelain" ] <> ""

let configmap_name (t : t) : string =
  Printf.sprintf "sol-deployment-%s" (Sol_cli_deployment_id.to_string t.deployment_id)
;;

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
    ; ( "actor_source"
      , match t.actor_source with
        | None -> `Null
        | Some s -> `String s )
    ; ( "target"
      , match t.target with
        | None -> `Null
        | Some x -> `String x )
    ; "mode", `String t.mode
    ; "requested_scope", `String t.requested_scope
    ; ( "profile"
      , match t.profile with
        | None -> `Null
        | Some p -> `String (Sol_cli_profile.to_string p) )
    ; "outcome", `String (outcome_to_string t.outcome)
    ]
;;

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
          let profile =
            match mem "profile" json with
            | None | Some `Null -> Ok None
            | Some (`String raw) ->
              Sol_cli_profile.of_string raw
              |> Result.map Option.some
              |> Result.map_error
                   (Printf.sprintf "deployment record has an invalid profile: %s")
            | Some _ -> Error "deployment record has an invalid profile: not a string"
          in
          (match outcome_of_string (str "outcome" json), profile with
           | Error msg, _ | _, Error msg -> Error msg
           | Ok outcome, Ok profile ->
             Ok
               { deployment_id
               ; release_id
               ; workspace
               ; environment = string_option "environment" json
               ; created_at = str "created_at" json
               ; git_commit = str "git_commit" json
               ; git_dirty = bool "git_dirty" json
               ; actor = string_option "actor" json
               ; actor_source = string_option "actor_source" json
               ; target = string_option "target" json
               ; mode = str "mode" json
               ; requested_scope = str "requested_scope" json
               ; profile
               ; outcome
               })))
;;

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

let item_name item =
  match mem "metadata" item with
  | Some metadata -> str "name" metadata
  | None -> ""
;;

let parse_kubectl_list (json : Yojson.Safe.t) : (t list, string) result =
  let corrupt label msg =
    Error
      (Printf.sprintf "deployment history contains an invalid record: %s: %s" label msg)
  in
  let open Result.Syntax in
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
            (match Sol_cli_json.decode ~what:"data.record" record with
             | Error msg -> corrupt label msg
             | Ok parsed ->
               (match of_json parsed with
                | Error msg -> corrupt label msg
                | Ok r ->
                  (match validate ~name r with
                   | Error msg -> corrupt label msg
                   | Ok () -> go (r :: acc) rest)))
          | _ -> corrupt label "has no data.record"))
  in
  let* items =
    Sol_cli_json.require ~what:"deployment list" [ "items" ] Sol_cli_json.list json
  in
  go [] items
;;

let format_table (records : t list) : string =
  let sorted =
    records
    |> List.sort (fun a b ->
      let by_time = String.compare b.created_at a.created_at in
      if by_time <> 0
      then by_time
      else
        String.compare
          (Sol_cli_deployment_id.to_string b.deployment_id)
          (Sol_cli_deployment_id.to_string a.deployment_id))
  in
  let actor_of r =
    match r.actor, r.actor_source with
    | Some name, Some source -> Printf.sprintf "%s (%s)" name source
    | Some name, None -> name
    | None, _ -> "-"
  in
  let rows =
    sorted
    |> List.map (fun r ->
      [ Sol_cli_deployment_id.to_string r.deployment_id
      ; Sol_cli_release_id.to_string r.release_id
      ; r.created_at
      ; (if String.equal r.git_commit "" then "-" else r.git_commit)
      ; outcome_to_string r.outcome
      ; actor_of r
      ])
  in
  let headers = [ "DEPLOYMENT"; "RELEASE"; "TIME"; "COMMIT"; "STATUS"; "ACTOR" ] in
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
