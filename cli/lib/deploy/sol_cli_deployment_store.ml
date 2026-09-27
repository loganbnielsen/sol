let with_temp_json json f =
  Sol_cli_fs.with_temp_file ~prefix:"sol-deployment-" ~suffix:".json" json f
  |> Result.join
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
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "configmap"; "-n"; "default"; "-l"; selector; "-o"; "json" ]
  with
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = Sol_cli_process.failure_message r in
    Error (Printf.sprintf "kubectl get configmap failed: %s" (String.trim detail))
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok r ->
    Sol_cli_json.decode ~what:"kubectl output" r.stdout
    |> Fun.flip Result.bind Sol_cli_deployment.parse_kubectl_list
;;
