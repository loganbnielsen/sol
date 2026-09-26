(* Writes and reads deployment-event records through kubectl (FEAT-070).

   Unlike the release store there is no pointer: one immutable ConfigMap per
   event, appended. FEAT-063: records live in the cluster the target names, so
   the entry points take the destination-side context. *)

let with_temp_json json (f : string -> 'a) : 'a =
  let path = Filename.temp_file "sol-deployment-" ".json" in
  let oc = open_out path in
  output_string oc json;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () -> f path)
;;

let record ~ctx (t : Sol_cli_deployment.t) : (unit, string) result =
  with_temp_json (Sol_cli_deployment.to_configmap_json t) (fun path ->
    match Sol_cli_kubectl.apply ~ctx ~file:path with
    | Ok () -> Ok ()
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let list ~ctx ~(workspace : string) : (Sol_cli_deployment.t list, string) result =
  let selector =
    Printf.sprintf
      "sol.dev/type=deployment,sol.dev/workspace=%s"
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
       Sol_cli_deployment.parse_kubectl_list
         (Yojson.Safe.from_string r.Sol_cli_process.stdout)
     with
     | Yojson.Json_error msg ->
       Error (Printf.sprintf "could not parse kubectl output: %s" msg))
;;
