(* Writes and reads release records through kubectl (FEAT-067). The write path
   is two applies: the immutable per-release ConfigMap, then the mutable pointer
   naming the current release. A failure to write is reported to the caller,
   which decides whether it is fatal — recording must never pretend to have
   happened. *)

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

let apply_json json =
  with_temp_json json (fun path ->
    match Sol_cli_kubectl.apply ~file:path with
    | Ok () -> Ok ()
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let record (t : Sol_cli_release.t) : (unit, string) result =
  match apply_json (Sol_cli_release.to_configmap_json t) with
  | Error e -> Error e
  | Ok () -> apply_json (Sol_cli_release.to_current_configmap_json t)
;;

(* Provenance is read here rather than threaded from the command, so [sol up]
   and [sol deploy] record the same two facts the same way. *)
let record_plan
      ~(workspace : string)
      ~(target : string)
      ~(mode : string)
      (plan : Sol_cli_deployment_plan.t)
  : (unit, string) result
  =
  record
    (Sol_cli_release.of_plan
       ~workspace
       ~target
       ~mode
       ~git_commit:(Sol_cli_release.git_commit ())
       ~git_dirty:(Sol_cli_release.git_dirty ())
       plan)
;;

let list ~(workspace : string) : (Sol_cli_release.t list, string) result =
  let selector =
    Printf.sprintf
      "sol.dev/type=release,sol.dev/workspace=%s"
      (Sol_cli_release.sanitize_label workspace)
  in
  match
    Sol_cli_kubectl.get_raw
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
