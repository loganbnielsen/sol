type holder =
  | Deploy
  | Rollback

let holder_to_string = function
  | Deploy -> "deploy"
  | Rollback -> "rollback"
;;

let holder_of_string = function
  | "deploy" -> Ok Deploy
  | "rollback" -> Ok Rollback
  | s ->
    Error
      (Printf.sprintf
         "%S is not a valid boundary-lease holder (expected \"deploy\" or \"rollback\")"
         s)
;;

type t =
  { boundary : string
  ; holder : holder
  ; run_id : string
  ; started_at : float
  ; heartbeat_at : float
  ; abort_requested : bool
  ; abort_reason : string option
  }

let default_ttl_s = 300.0
let rollback_wait_s = 300.0
let poll_interval_s = 2.0
let max_cas_attempts = 8

let configmap_name ~workspace =
  "sol-boundary-lease-" ^ Sol_cli_kubernetes_name.sanitize_name workspace
;;

let make_run_id ~holder ~now ~pid =
  Printf.sprintf "%s-%s-%d" (holder_to_string holder) (Sol_cli_time.rfc3339 now) pid
;;

let create ~boundary ~holder ~run_id ~now =
  { boundary
  ; holder
  ; run_id
  ; started_at = now
  ; heartbeat_at = now
  ; abort_requested = false
  ; abort_reason = None
  }
;;

let with_heartbeat t ~now = { t with heartbeat_at = now }

let with_abort_requested t ~reason =
  { t with abort_requested = true; abort_reason = Some reason }
;;

let is_stale ~now ~ttl t = now -. t.heartbeat_at > ttl

let describe t =
  Printf.sprintf
    "%s run %s (started %s)"
    (holder_to_string t.holder)
    t.run_id
    (Sol_cli_time.rfc3339 t.started_at)
;;

type decision =
  | Proceed
  | Request_abort of string
  | Refuse of string

let deploy_decision ~now ~ttl = function
  | None -> Proceed
  | Some t when is_stale ~now ~ttl t -> Proceed
  | Some t ->
    Refuse
      (Printf.sprintf
         "another operation holds the %s boundary: %s. Wait for it to finish, then retry."
         t.boundary
         (describe t))
;;

let rollback_decision ~now ~ttl = function
  | None -> Proceed
  | Some t when is_stale ~now ~ttl t -> Proceed
  | Some t ->
    (match t.holder with
     | Deploy ->
       Request_abort
         (Printf.sprintf
            "an in-flight deploy holds the %s boundary: %s. Requesting it stop before \
             restoring."
            t.boundary
            (describe t))
     | Rollback ->
       Refuse
         (Printf.sprintf
            "cannot establish quiescence on the %s boundary: another rollback is running \
             (%s). Retry after it completes."
            t.boundary
            (describe t)))
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

let float_field key json =
  match mem key json with
  | Some (`String s) ->
    (match float_of_string_opt (String.trim s) with
     | Some value when Float.is_finite value && Sol_cli_time.is_representable value ->
       Ok value
     | Some _ ->
       Error (Printf.sprintf "boundary lease: %s is not a representable time" key)
     | None -> Error (Printf.sprintf "boundary lease: %s is not a number" key))
  | Some _ -> Error (Printf.sprintf "boundary lease: %s is not a string" key)
  | None -> Error (Printf.sprintf "boundary lease: %s is missing" key)
;;

let required_string data ~field =
  match mem field data with
  | Some (`String value) when not (Sol_cli_string.is_blank value) -> Ok value
  | Some (`String _) -> Error (Printf.sprintf "boundary lease: %s is blank" field)
  | Some _ -> Error (Printf.sprintf "boundary lease: %s is not a string" field)
  | None -> Error (Printf.sprintf "boundary lease: %s is missing" field)
;;

let abort_requested_field data =
  match mem "abort_requested" data with
  | Some (`String "true") -> Ok true
  | Some (`String "false") -> Ok false
  | Some (`String other) ->
    Error
      (Printf.sprintf
         "boundary lease: abort_requested is %S, not \"true\" or \"false\""
         other)
  | Some _ -> Error "boundary lease: abort_requested is not a string"
  | None -> Error "boundary lease: abort_requested is missing"
;;

let resource_version_of item =
  match mem "metadata" item with
  | Some metadata ->
    (match mem "resourceVersion" metadata with
     | Some (`String value) when not (Sol_cli_string.is_blank value) -> Ok value
     | Some (`String _) ->
       Error
         "boundary lease: resourceVersion is blank, so it cannot be compared and swapped \
          safely"
     | Some _ -> Error "boundary lease: resourceVersion is not a string"
     | None ->
       Error
         "boundary lease: resourceVersion is missing, so it cannot be compared and \
          swapped safely")
  | None -> Error "boundary lease: metadata is missing"
;;

let to_data_json t =
  `Assoc
    [ "boundary", `String t.boundary
    ; "holder", `String (holder_to_string t.holder)
    ; "run_id", `String t.run_id
    ; "started_at", `String (Printf.sprintf "%.3f" t.started_at)
    ; "heartbeat_at", `String (Printf.sprintf "%.3f" t.heartbeat_at)
    ; "abort_requested", `String (string_of_bool t.abort_requested)
    ; ( "abort_reason"
      , `String
          (match t.abort_reason with
           | None -> ""
           | Some r -> r) )
    ]
;;

let to_configmap_json ?resource_version t =
  let metadata =
    [ "name", `String (configmap_name ~workspace:t.boundary)
    ; "namespace", `String "default"
    ; ( "labels"
      , `Assoc
          [ "sol.dev/type", `String "boundary-lease"
          ; "sol.dev/workspace", `String (Sol_cli_release.sanitize_label t.boundary)
          ] )
    ]
    @
    match Sol_cli_string.non_empty resource_version with
    | None -> []
    | Some rv -> [ "resourceVersion", `String rv ]
  in
  Yojson.Safe.pretty_to_string
    (`Assoc
        [ "apiVersion", `String "v1"
        ; "kind", `String "ConfigMap"
        ; "metadata", `Assoc metadata
        ; "data", to_data_json t
        ])
;;

let of_configmap_item item =
  let open Result.Syntax in
  let* data =
    match mem "data" item with
    | Some data -> Ok data
    | None -> Error "boundary lease has no data"
  in
  let* resource_version = resource_version_of item in
  let* holder =
    match holder_of_string (str "holder" data) with
    | Ok holder -> Ok holder
    | Error msg -> Error (Printf.sprintf "boundary lease: %s" msg)
  in
  let* boundary = required_string data ~field:"boundary" in
  let* run_id = required_string data ~field:"run_id" in
  let* started_at = float_field "started_at" data in
  let* heartbeat_at = float_field "heartbeat_at" data in
  let* abort_requested = abort_requested_field data in
  Ok
    ( { boundary
      ; holder
      ; run_id
      ; started_at
      ; heartbeat_at
      ; abort_requested
      ; abort_reason =
          (match str "abort_reason" data with
           | "" -> None
           | reason -> Some reason)
      }
    , resource_version )
;;

type write_error =
  | Already_exists
  | Conflict
  | Other of string

let with_temp_json json f =
  Sol_cli_fs.with_temp_file ~prefix:"sol-lease-" ~suffix:".json" json f
  |> Result.map_error (fun message -> Other message)
  |> Result.join
;;

let create_object ~ctx t =
  with_temp_json (to_configmap_json t) (fun path ->
    match Sol_cli_kubectl.create ~ctx ~file:path with
    | Ok _ -> Ok ()
    | Error e when Sol_cli_kubectl.classify e = Already_exists -> Error Already_exists
    | Error e -> Error (Other (Sol_cli_process.error_to_string e)))
;;

let replace_object ~ctx t ~resource_version =
  with_temp_json (to_configmap_json ~resource_version t) (fun path ->
    match Sol_cli_kubectl.replace ~ctx ~file:path with
    | Ok _ -> Ok ()
    | Error e when Sol_cli_kubectl.classify e = Conflict -> Error Conflict
    | Error e -> Error (Other (Sol_cli_process.error_to_string e)))
;;

let fetch ~ctx ~workspace =
  let name = configmap_name ~workspace in
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:[ "get"; "configmap"; name; "-n"; "default"; "-o"; "json" ]
  with
  | Ok None -> Ok None
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok (Some body) ->
    Sol_cli_json.decode ~what:"boundary lease" body
    |> Fun.flip Result.bind of_configmap_item
    |> Result.map Option.some
;;

let remove ~ctx ~workspace =
  Sol_cli_kubectl.delete
    ~ctx
    ~resource:"configmap"
    ~name:(configmap_name ~workspace)
    ~namespace:"default"
  |> Result.map_error Sol_cli_process.error_to_string
;;

let refetch ~ctx ~workspace =
  let open Result.Syntax in
  let* lease = fetch ~ctx ~workspace in
  match lease with
  | Some x -> Ok x
  | None -> Error "the boundary lease disappeared immediately after it was written"
;;

type held =
  { ctx : Sol_cli_kube_destination.context
  ; lease : t
  ; run_id : string
  }

let acquire_raw ~ctx ~workspace ~holder ~run_id ~ttl ~wait_s =
  let deadline = Unix.gettimeofday () +. max wait_s 0.0 in
  let attempts_budget =
    max
      max_cas_attempts
      (int_of_float (max wait_s 0.0 /. poll_interval_s) + max_cas_attempts)
  in
  let rec go attempts =
    if attempts <= 0
    then Error "boundary lease contention: repeated compare-and-swap conflicts"
    else (
      let now = Unix.gettimeofday () in
      let open Result.Syntax in
      let* lease = fetch ~ctx ~workspace in
      match lease with
      | None ->
        (match create_object ~ctx (create ~boundary:workspace ~holder ~run_id ~now) with
         | Ok () -> refetch ~ctx ~workspace
         | Error Already_exists | Error Conflict -> go (attempts - 1)
         | Error (Other m) ->
           Error
             (Printf.sprintf "could not acquire the %s boundary lease: %s" workspace m))
      | Some (existing, resource_version) ->
        let decision =
          (match holder with
           | Deploy -> deploy_decision
           | Rollback -> rollback_decision)
            ~now
            ~ttl
            (Some existing)
        in
        (match decision with
         | Proceed ->
           (match
              replace_object
                ~ctx
                (create ~boundary:workspace ~holder ~run_id ~now)
                ~resource_version
            with
            | Ok () -> refetch ~ctx ~workspace
            | Error Conflict | Error Already_exists -> go (attempts - 1)
            | Error (Other m) ->
              Error
                (Printf.sprintf "could not acquire the %s boundary lease: %s" workspace m))
         | Refuse msg -> Error msg
         | Request_abort reason ->
           if now >= deadline
           then
             Error
               (Printf.sprintf
                  "cannot establish quiescence on the %s boundary: %s is still running \
                   after the abort request. Refusing rather than racing it."
                  workspace
                  (describe existing))
           else (
             Sol_cli_report.warn "warning: %s" reason;
             let aborted = with_abort_requested existing ~reason in
             match replace_object ~ctx aborted ~resource_version with
             | Error Conflict -> go (attempts - 1)
             | Error Already_exists -> go (attempts - 1)
             | Error (Other m) ->
               Error (Printf.sprintf "could not request the deploy stop: %s" m)
             | Ok () ->
               Unix.sleepf poll_interval_s;
               go (attempts - 1))))
  in
  go attempts_budget
;;

let acquire ~ctx ~workspace ~holder ~ttl ~wait_s =
  let now = Unix.gettimeofday () in
  let run_id = make_run_id ~holder ~now ~pid:(Unix.getpid ()) in
  acquire_raw ~ctx ~workspace ~holder ~run_id ~ttl ~wait_s
  |> Result.map (fun (lease, _resource_version) -> { ctx; lease; run_id })
;;

type heartbeat_result =
  | Held
  | Aborted of string

let heartbeat_raw ~ctx t ~run_id =
  let rec go attempts =
    if attempts <= 0
    then Error "lost the boundary lease: repeated compare-and-swap conflicts"
    else
      let open Result.Syntax in
      let* lease = fetch ~ctx ~workspace:t.boundary in
      match lease with
      | None -> Error (Printf.sprintf "lost the %s boundary lease: it is gone" t.boundary)
      | Some (current, resource_version) ->
        if not (String.equal current.run_id run_id)
        then
          Error
            (Printf.sprintf
               "lost the %s boundary lease to %s"
               t.boundary
               (describe current))
        else if current.abort_requested
        then
          Ok
            (Aborted
               (match current.abort_reason with
                | Some r -> r
                | None -> "a rollback requested this deploy stop"))
        else (
          match
            replace_object
              ~ctx
              (with_heartbeat current ~now:(Unix.gettimeofday ()))
              ~resource_version
          with
          | Ok () -> Ok Held
          | Error Conflict -> go (attempts - 1)
          | Error Already_exists -> go (attempts - 1)
          | Error (Other m) -> Error m)
  in
  go max_cas_attempts
;;

let heartbeat (h : held) = heartbeat_raw ~ctx:h.ctx h.lease ~run_id:h.run_id

let ensure_held h =
  match heartbeat h with
  | Ok Held -> Ok ()
  | Ok (Aborted reason) ->
    Error
      (Printf.sprintf
         "deploy aborted: %s. The boundary was left for the rollback to restore."
         reason)
  | Error msg -> Error (Printf.sprintf "lost the boundary lease: %s" msg)
;;

let release_raw ~ctx t =
  let open Result.Syntax in
  let* lease = fetch ~ctx ~workspace:t.boundary in
  match lease with
  | None -> Ok ()
  | Some (current, _) ->
    if String.equal current.run_id t.run_id
    then remove ~ctx ~workspace:t.boundary
    else
      Error
        (Printf.sprintf
           "refusing to release the %s boundary lease: it is now held by %s"
           t.boundary
           (describe current))
;;

let release (h : held) = release_raw ~ctx:h.ctx h.lease

let release_with_warning h =
  release h
  |> Result.iter_error (fun msg ->
    Sol_cli_report.warn "warning: could not release the boundary lease: %s" msg)
;;

let with_boundary_lease ~ctx ~workspace ~holder ~ttl ~wait_s f =
  let open Result.Syntax in
  let* held = acquire ~ctx ~workspace ~holder ~ttl ~wait_s in
  Fun.protect ~finally:(fun () -> release_with_warning held) (fun () -> f held)
;;
