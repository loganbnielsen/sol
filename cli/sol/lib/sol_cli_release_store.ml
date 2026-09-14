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

let apply_json ~ctx json =
  with_temp_json json (fun path ->
    match Sol_cli_kubectl.apply ~ctx ~file:path with
    | Ok () -> Ok ()
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let record ~ctx (t : Sol_cli_release.t) : (unit, string) result =
  match apply_json ~ctx (Sol_cli_release.to_configmap_json t) with
  | Error e -> Error e
  | Ok () -> apply_json ~ctx (Sol_cli_release.to_current_configmap_json t)
;;

(* FEAT-069: the record is content-addressed, so it is built from the plan's
   own [release_id] and content — no invocation provenance is read or threaded
   here. [sol up] and [sol deploy] therefore record the same artifact. *)
let record_plan ~ctx (plan : Sol_cli_deployment_plan.t) : (unit, string) result =
  record ~ctx (Sol_cli_release.of_plan plan)
;;

let list ~ctx ~(workspace : string) : (Sol_cli_release.t list, string) result =
  let selector =
    Printf.sprintf
      "sol.dev/type=release,sol.dev/workspace=%s"
      (Sol_cli_release.sanitize_label workspace)
  in
  match
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "configmap"; "-n"; "default"; "-l"; selector; "-o"; "json" ]
  with
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok r when r.Sol_cli_process.exit_code <> 0 ->
    let detail =
      if r.Sol_cli_process.stderr <> ""
      then r.Sol_cli_process.stderr
      else r.Sol_cli_process.stdout
    in
    Error (Printf.sprintf "kubectl get configmap failed: %s" (String.trim detail))
  | Ok r ->
    (try
       Sol_cli_release.parse_kubectl_list
         (Yojson.Safe.from_string r.Sol_cli_process.stdout)
     with
     | Yojson.Json_error msg ->
       Error (Printf.sprintf "could not parse kubectl output: %s" msg))
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
     | Error e -> Error (Sol_cli_process.error_to_string e)
     | Ok r when r.Sol_cli_process.exit_code <> 0 ->
       let detail =
         if r.Sol_cli_process.stderr <> ""
         then r.Sol_cli_process.stderr
         else r.Sol_cli_process.stdout
       in
       if Sol_cli_port_forward.string_contains ~needle:"NotFound" detail
       then
         Error (Printf.sprintf "release %s not found" (Sol_cli_release_id.to_string id))
       else Error (Printf.sprintf "kubectl get configmap failed: %s" (String.trim detail))
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

let move_pointer ~ctx (t : Sol_cli_release.t) : (unit, string) result =
  apply_json ~ctx (Sol_cli_release.to_current_configmap_json t)
;;
