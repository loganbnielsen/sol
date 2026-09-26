(* Writes and reads release records through kubectl (FEAT-067). The write path
   is two applies: the immutable per-release ConfigMap, then the mutable pointer
   naming the current release. A failure to write is reported to the caller,
   which decides whether it is fatal — recording must never pretend to have
   happened.

   FEAT-063: records live in the cluster the target names, so each entry point
   takes the destination-side context and hands it to kubectl. *)

let with_temp_json json (f : string -> 'a) : 'a =
  let path = Filename.temp_file "sol-release-" ".json" in
  let oc = open_out path in
  output_string oc json;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () -> f path)
;;

(* ── DEC-037 / INFRA-055: writing with the verbs the deploy identity holds ────

   [kubectl apply] degrades to a *patch* when the object already exists, and the
   boundary-lease grant deliberately withholds `patch` on ConfigMaps in `default`
   (`platform_deploy_rbac.tf`). So every write after the first was refused, and the
   release pointer silently stayed on an older release while the deploy reported
   success. `create` and `update` -- the verb `kubectl replace` uses -- are both
   granted, which is the narrower mechanism: the deploy role does not acquire
   generic `patch` in `default`, the verb that would also let it rewrite the
   boundary lease that serialises deploys.

   Three consequences worth stating:

   - An object whose [data] already matches is left alone. That matters for the
     content-addressed record: re-deploying identical content re-writes the same
     object name, and the immutable record would reject a changed replace anyway.
   - Optimistic concurrency travels *in the object*: the replace carries the live
     object's [resourceVersion], so a concurrent writer is a conflict rather than a
     silent overwrite.
   - Both of the above are only sound because the whole record step runs inside the
     workspace boundary lease (`cmd_deploy.ml`'s [run_apply], and `cmd_up.ml`).
     Moving it outside that lease would reintroduce a lost-update window. *)

let metadata_string json key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "metadata" fields with
     | Some (`Assoc meta) ->
       (match List.assoc_opt key meta with
        | Some (`String value) -> Some value
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let data_of_json json =
  match json with
  | `Assoc fields -> List.assoc_opt "data" fields
  | _ -> None
;;

(* The live object's [data] and [resourceVersion], or [None] when it does not
   exist. A read that fails for any *other* reason is an error: a permission
   failure must never be mistaken for absence and answered with a create. *)
let fetch_live ~ctx ~name ~namespace =
  match
    Sol_cli_process.check
      (Sol_cli_kubectl.get_raw
         ~ctx
         ~args:[ "get"; "configmap"; name; "-n"; namespace; "-o"; "json" ])
  with
  | Ok r ->
    (try
       let json = Yojson.Safe.from_string r.Sol_cli_process.stdout in
       Ok (Some (data_of_json json, metadata_string json "resourceVersion"))
     with
     | _ ->
       Error (Printf.sprintf "could not parse the live ConfigMap %s/%s" namespace name))
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim (r.stderr ^ " " ^ r.stdout) in
    if Sol_cli_string.contains ~needle:"NotFound" detail
    then Ok None
    else
      Error
        (Printf.sprintf
           "kubectl get configmap %s failed: %s"
           name
           (if String.equal detail "" then "no output" else detail))
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

let failure_detail ~stdout ~stderr =
  match Sol_cli_process.failure_output ~stdout ~stderr with
  | "" -> "no output"
  | output -> output
;;

let with_resource_version json (resource_version : string option) =
  match resource_version, json with
  | None, _ | _, `Assoc _ ->
    (match json with
     | `Assoc fields ->
       let meta =
         match List.assoc_opt "metadata" fields with
         | Some (`Assoc meta) -> meta
         | _ -> []
       in
       let meta =
         match resource_version with
         | None -> meta
         | Some rv ->
           ("resourceVersion", `String rv) :: List.remove_assoc "resourceVersion" meta
       in
       `Assoc (("metadata", `Assoc meta) :: List.remove_assoc "metadata" fields)
     | other -> other)
  | _ -> json
;;

let write_one ~ctx ~verb ~name json =
  with_temp_json (Yojson.Safe.to_string json) (fun path ->
    let result =
      match verb with
      | `Create -> Sol_cli_kubectl.create ~ctx ~file:path
      | `Replace -> Sol_cli_kubectl.replace ~ctx ~file:path
    in
    match Sol_cli_process.check result with
    | Ok _ -> Ok ()
    | Error (Sol_cli_process.Non_zero r) ->
      Error
        (Printf.sprintf
           "kubectl %s configmap %s failed: %s"
           (match verb with
            | `Create -> "create"
            | `Replace -> "replace")
           name
           (failure_detail ~stdout:r.stdout ~stderr:r.stderr))
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let write_json ~ctx json =
  match metadata_string json "name", metadata_string json "namespace" with
  | None, _ | _, None -> Error "release ConfigMap is missing metadata.name/namespace"
  | Some name, Some namespace ->
    (match fetch_live ~ctx ~name ~namespace with
     | Error e -> Error e
     | Ok (Some (live_data, _)) when live_data = data_of_json json -> Ok ()
     | Ok (Some (_, live_rv)) ->
       write_one ~ctx ~verb:`Replace ~name (with_resource_version json live_rv)
     | Ok None -> write_one ~ctx ~verb:`Create ~name json)
;;

let parse_configmap json =
  try Ok (Yojson.Safe.from_string json) with
  | _ -> Error "release ConfigMap is not valid JSON"
;;

let record ~ctx (t : Sol_cli_release.t) : (unit, string) result =
  match parse_configmap (Sol_cli_release.to_configmap_json t) with
  | Error e -> Error e
  | Ok json ->
    (match write_json ~ctx json with
     | Error e -> Error e
     | Ok () ->
       parse_configmap (Sol_cli_release.to_current_configmap_json t)
       |> (function
        | Error e -> Error e
        | Ok json -> write_json ~ctx json))
;;

(* FEAT-069: the record is content-addressed, so it is built from the plan's
   own [release_id] and content — no invocation provenance is read or threaded
   here. [sol up] and [sol deploy] therefore record the same artifact. FEAT-066:
   [~apply_mode] is the owning/application mode of *this* release (direct vs
   GitOps-emitted), recorded as non-identity historical metadata. *)
let record_plan
      ~ctx
      ~(apply_mode : Sol_cli_release.apply_mode)
      (plan : Sol_cli_deployment_plan.t)
  : (unit, string) result
  =
  record ~ctx (Sol_cli_release.of_plan ~apply_mode plan)
;;

let list_with_creation ~ctx ~(workspace : string)
  : ((Sol_cli_release.t * string) list, string) result
  =
  let selector =
    Printf.sprintf
      "sol.dev/type=release,sol.dev/workspace=%s"
      (Sol_cli_release.sanitize_label workspace)
  in
  match
    Sol_cli_process.check
      (Sol_cli_kubectl.get_raw
         ~ctx
         ~args:[ "get"; "configmap"; "-n"; "default"; "-l"; selector; "-o"; "json" ])
  with
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = Sol_cli_process.failure_output ~stdout:r.stdout ~stderr:r.stderr in
    Error (Printf.sprintf "kubectl get configmap failed: %s" (String.trim detail))
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok r ->
    (try
       Sol_cli_release.parse_kubectl_list_with_creation
         (Yojson.Safe.from_string r.Sol_cli_process.stdout)
     with
     | Yojson.Json_error msg ->
       Error (Printf.sprintf "could not parse kubectl output: %s" msg))
;;

let list ~ctx ~(workspace : string) : (Sol_cli_release.t list, string) result =
  list_with_creation ~ctx ~workspace |> Result.map (List.map fst)
;;

let get ~ctx ~(workspace : string) ~(release_id : string)
  : (Sol_cli_release.t, string) result
  =
  match Sol_cli_release_id.of_string release_id with
  | Error msg -> Error msg
  | Ok id ->
    let name = Printf.sprintf "sol-release-%s" (Sol_cli_release_id.to_string id) in
    (match
       Sol_cli_kubectl.get
         ~ctx
         ~resource:"configmap"
         ~name
         ~namespace:"default"
         ~output:"json"
     with
     | Error (Sol_cli_process.Non_zero r) ->
       let detail = Sol_cli_process.failure_output ~stdout:r.stdout ~stderr:r.stderr in
       if Sol_cli_string.contains ~needle:"NotFound" detail
       then
         Error (Printf.sprintf "release %s not found" (Sol_cli_release_id.to_string id))
       else Error (Printf.sprintf "kubectl get configmap failed: %s" (String.trim detail))
     | Error e -> Error (Sol_cli_process.error_to_string e)
     | Ok r ->
       (match
          match Yojson.Safe.from_string r.Sol_cli_process.stdout with
          | json -> Ok json
          | exception Yojson.Json_error msg ->
            Error (Printf.sprintf "could not parse kubectl output: %s" msg)
        with
        | Error e -> Error e
        | Ok json ->
          (match Sol_cli_release.of_kubectl_item json with
           | Error msg -> Error msg
           | Ok record ->
             if String.equal record.Sol_cli_release.workspace workspace
             then Ok record
             else
               Error
                 (Printf.sprintf
                    "release %s belongs to workspace %S, not %S"
                    (Sol_cli_release_id.to_string id)
                    record.Sol_cli_release.workspace
                    workspace))))
;;

(* FEAT-072: the pointer's [data.release_id], read without loading the record.
   Retention needs the pre-transition "current" to protect it, and rollback
   already has its own record reader. [None] means there is no pointer yet (or it
   is empty), not an error: a workspace that has never deployed has no history to
   protect. *)
let current ~ctx ~(workspace : string) : (string option, string) result =
  let name = Sol_cli_release.current_configmap_name ~workspace in
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:"configmap"
      ~name
      ~namespace:"default"
      ~output:"jsonpath={.data.release_id}"
  with
  | Error (Sol_cli_process.Non_zero { stderr; _ })
    when Sol_cli_string.contains ~needle:"NotFound" stderr -> Ok None
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok r ->
    let value = String.trim r.Sol_cli_process.stdout in
    if String.equal value "" then Ok None else Ok (Some value)
;;

(* FEAT-072: delete one release record. Only the immutable per-release ConfigMap
   is touched, never the pointer. The id is validated first, so a malformed id
   cannot reach an object name. *)
let delete ~ctx ~(release_id : string) : (unit, string) result =
  match Sol_cli_release_id.of_string release_id with
  | Error msg -> Error msg
  | Ok id ->
    let name = Printf.sprintf "sol-release-%s" (Sol_cli_release_id.to_string id) in
    Sol_cli_kubectl.delete ~ctx ~resource:"configmap" ~name ~namespace:"default"
    |> Result.map_error Sol_cli_process.error_to_string
;;

let move_pointer ~ctx (t : Sol_cli_release.t) : (unit, string) result =
  (* INFRA-055: rollback moves the same pointer, so it uses the same writer --
     one mechanism, one set of verbs, one place for the lease constraint. *)
  match parse_configmap (Sol_cli_release.to_current_configmap_json t) with
  | Error e -> Error e
  | Ok json -> write_json ~ctx json
;;
