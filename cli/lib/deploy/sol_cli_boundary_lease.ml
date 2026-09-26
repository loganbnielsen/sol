(* FEAT-072: the per-boundary mutation lease, shared by deploy and rollback.
   See the .mli for the design. This is a thin, fail-closed coordination layer:
   the decision of what to do with a lease is pure and tested; the kubectl writes
   are the only impure part. *)

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

(* Five minutes without a heartbeat is long enough that a slow but living apply
   is not mistaken for a crash, and short enough that a killed process does not
   strand the boundary for the rest of the day. Deploy refreshes before each
   workload apply; a single apply that itself blocks longer than this is outside
   the guarantee, which is why the value is exposed rather than hardcoded. *)
let default_ttl_s = 300.0

(* Rollback asks an in-flight deploy to stop and waits this long for it to
   release the boundary. If the holder is genuinely alive but not honouring the
   abort, refusing is the whole point (DEC-018): better to stop than to race. *)
let rollback_wait_s = 300.0
let poll_interval_s = 2.0
let max_cas_attempts = 8

let configmap_name ~workspace =
  "sol-boundary-lease-" ^ Sol_cli_kubernetes_name.sanitize_name workspace
;;

let make_run_id ~holder ~now ~pid =
  Printf.sprintf
    "%s-%s-%d"
    (holder_to_string holder)
    (Sol_cli_deployment.rfc3339_utc now)
    pid
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
    (Sol_cli_deployment.rfc3339_utc t.started_at)
;;

(* ── pure decisions ───────────────────────────────────────────────────────── *)

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

(* ── serialization ────────────────────────────────────────────────────────── *)

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
  | Some (`String s) -> float_of_string_opt s
  | _ -> None
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

(* [resource_version], when given, is written into the object's metadata so the
   API server rejects the write if the stored version has moved (FEAT-072's
   optimistic take-over). The compare-and-swap lives in the object rather than in
   a kubectl flag, because not every kubectl has [replace --resource-version]. *)
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
  let resource_version =
    match mem "metadata" item with
    | Some metadata -> str "resourceVersion" metadata
    | None -> ""
  in
  match mem "data" item with
  | None -> Error "boundary lease has no data"
  | Some data ->
    (match holder_of_string (str "holder" data) with
     | Error msg -> Error (Printf.sprintf "boundary lease: %s" msg)
     | Ok holder ->
       let boundary = str "boundary" data in
       if String.equal boundary ""
       then Error "boundary lease is missing its boundary"
       else (
         match float_field "started_at" data, float_field "heartbeat_at" data with
         | Some started_at, Some heartbeat_at ->
           Ok
             ( { boundary
               ; holder
               ; run_id = str "run_id" data
               ; started_at
               ; heartbeat_at
               ; abort_requested =
                   (match mem "abort_requested" data with
                    | Some (`String "true") -> true
                    | _ -> false)
               ; abort_reason =
                   (match str "abort_reason" data with
                    | "" -> None
                    | r -> Some r)
               }
             , resource_version )
         | _ -> Error "boundary lease is missing a valid started_at/heartbeat_at"))
;;

(* ── cluster writes ───────────────────────────────────────────────────────── *)

let with_temp_json json (f : string -> 'a) : 'a =
  let path = Filename.temp_file "sol-lease-" ".json" in
  let oc = open_out path in
  output_string oc json;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () -> f path)
;;

let detail_of_result (r : Sol_cli_process.result) =
  let stderr = String.trim r.Sol_cli_process.stderr in
  if stderr <> "" then stderr else String.trim r.Sol_cli_process.stdout
;;

type write_error =
  | Already_exists
  | Conflict
  | Other of string

let create_object ~ctx t =
  with_temp_json (to_configmap_json t) (fun path ->
    match Sol_cli_kubectl.create ~ctx ~file:path with
    | Error e -> Error (Other (Sol_cli_process.error_to_string e))
    | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok ()
    | Ok r ->
      let detail = detail_of_result r in
      if Sol_cli_string.contains ~needle:"AlreadyExists" detail
      then Error Already_exists
      else Error (Other detail))
;;

let replace_object ~ctx t ~resource_version =
  with_temp_json (to_configmap_json ~resource_version t) (fun path ->
    match Sol_cli_kubectl.replace ~ctx ~file:path with
    | Error e -> Error (Other (Sol_cli_process.error_to_string e))
    | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok ()
    | Ok r ->
      let detail = detail_of_result r in
      if
        Sol_cli_string.contains ~needle:"the object has been modified" detail
        || Sol_cli_string.contains ~needle:"Operation cannot be fulfilled" detail
        || Sol_cli_string.contains ~needle:"please apply your changes" detail
      then Error Conflict
      else Error (Other detail))
;;

let fetch ~ctx ~workspace =
  let name = configmap_name ~workspace in
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:"configmap"
      ~name
      ~namespace:"default"
      ~output:"json"
  with
  | Error (Sol_cli_process.Non_zero { stderr; _ })
    when Sol_cli_string.contains ~needle:"NotFound" stderr
         || Sol_cli_string.contains ~needle:"not found" stderr -> Ok None
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok r ->
    (match Yojson.Safe.from_string r.Sol_cli_process.stdout with
     | exception Yojson.Json_error msg ->
       Error (Printf.sprintf "could not parse boundary lease: %s" msg)
     | json ->
       (match of_configmap_item json with
        | Error msg -> Error msg
        | Ok (t, resource_version) -> Ok (Some (t, resource_version))))
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
  match fetch ~ctx ~workspace with
  | Ok (Some x) -> Ok x
  | Ok None -> Error "the boundary lease disappeared immediately after it was written"
  | Error e -> Error e
;;

(* ── the held lease: acquire / heartbeat / release / bracket ───────────────── *)

(* A lease this process owns, plus everything its holder needs to refresh or
   release it. Returning this rather than a bare lease and a run id the caller
   must keep in step lets a call site write [heartbeat lease] / [release lease]
   instead of threading the context and run id by hand. *)
type held =
  { ctx : Sol_cli_kube_destination.context
  ; lease : t
  ; run_id : string
  }

let acquire_raw ~ctx ~workspace ~holder ~run_id ~ttl ~wait_s =
  let deadline = Unix.gettimeofday () +. max wait_s 0.0 in
  (* An abort-and-wait is a sequence of polls, so the attempt budget must cover
     the whole window; a plain CAS race needs only a handful. *)
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
      match fetch ~ctx ~workspace with
      | Error e -> Error e
      | Ok None ->
        (match create_object ~ctx (create ~boundary:workspace ~holder ~run_id ~now) with
         | Ok () -> refetch ~ctx ~workspace
         | Error Already_exists | Error Conflict -> go (attempts - 1)
         | Error (Other m) ->
           Error
             (Printf.sprintf "could not acquire the %s boundary lease: %s" workspace m))
      | Ok (Some (existing, resource_version)) ->
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
             Printf.eprintf "warning: %s\n%!" reason;
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
  match acquire_raw ~ctx ~workspace ~holder ~run_id ~ttl ~wait_s with
  | Ok (lease, _resource_version) -> Ok { ctx; lease; run_id }
  | Error msg -> Error msg
;;

type heartbeat_result =
  | Held
  | Aborted of string

let heartbeat_raw ~ctx t ~run_id =
  let rec go attempts =
    if attempts <= 0
    then Error "lost the boundary lease: repeated compare-and-swap conflicts"
    else (
      match fetch ~ctx ~workspace:t.boundary with
      | Error e -> Error e
      | Ok None ->
        Error (Printf.sprintf "lost the %s boundary lease: it is gone" t.boundary)
      | Ok (Some (current, resource_version)) ->
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
          | Error (Other m) -> Error m))
  in
  go max_cas_attempts
;;

let heartbeat (h : held) = heartbeat_raw ~ctx:h.ctx h.lease ~run_id:h.run_id

(* The shape a caller wants between one mutation and the next: [Ok ()] while the
   lease is still this process's and no abort was requested, an [Error] that
   explains why otherwise. *)
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
  match fetch ~ctx ~workspace:t.boundary with
  | Error e -> Error e
  | Ok None -> Ok ()
  | Ok (Some (current, _)) ->
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
  match release h with
  | Ok () -> ()
  | Error msg ->
    Printf.eprintf "warning: could not release the boundary lease: %s\n%!" msg
;;

(* [f] returns a result rather than calling [exit], so [Fun.protect] releases the
   lease exactly once on every path and no [at_exit] hook is needed. *)
let with_boundary_lease ~ctx ~workspace ~holder ~ttl ~wait_s f =
  match acquire ~ctx ~workspace ~holder ~ttl ~wait_s with
  | Error msg -> Error msg
  | Ok held ->
    Fun.protect ~finally:(fun () -> release_with_warning held) (fun () -> f held)
;;
