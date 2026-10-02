type execution_outcome =
  | Applied of
      { namespace : string
      ; name : string
      ; image : string
      ; consumer_groups : string list
      }
  | Emitted of { file : string }
  | Dry_run
  | Failed of
      { phase : string
      ; message : string
      }

let deploy_state_configmap_name workspace =
  Printf.sprintf "sol-deploy-state-%s" (Sol_cli_kubernetes_name.sanitize_name workspace)
;;

let load_deployed_groups ~ctx workspace =
  let name = deploy_state_configmap_name workspace in
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:
        [ "get"
        ; "configmap"
        ; name
        ; "-n"
        ; "default"
        ; "-o"
        ; "jsonpath={.data.consumer_groups}"
        ]
  with
  | Ok groups ->
    Ok
      (Option.value groups ~default:""
       |> String.split_on_char '\n'
       |> List.filter_map Sol_cli_string.non_blank)
  | Error e ->
    Error
      (Printf.sprintf
         "could not read the recorded consumer groups (configmap default/%s): %s"
         name
         (Sol_cli_process.error_to_string e))
;;

let removed_groups_message removed =
  String.concat
    ""
    [ "the following consumer group(s) are no longer present in this deploy plan:\n"
    ; String.concat "" (List.map (fun g -> Printf.sprintf "  - %s\n" g) removed)
    ; "\n\
       While a group is absent, nothing consumes its messages. If it is added back, it \
       resumes\n\
       from its committed offset while Kafka still retains it; once that offset has \
       expired\n\
       it starts from the EARLIEST retained offset and reprocesses the retained log, \
       repeating\n\
       side effects. Pass --confirm-group-change to acknowledge and proceed.\n\n"
    ]
;;

let save_deployed_groups ~ctx workspace groups =
  let name = deploy_state_configmap_name workspace in
  let value = String.concat "\n" groups in
  let apply_json =
    Yojson.Safe.to_string
      (`Assoc
          [ "apiVersion", `String "v1"
          ; "kind", `String "ConfigMap"
          ; "metadata", `Assoc [ "name", `String name; "namespace", `String "default" ]
          ; "data", `Assoc [ "consumer_groups", `String value ]
          ])
  in
  Sol_cli_fs.with_temp_file ~prefix:"sol-state-" ~suffix:".json" apply_json (fun path ->
    match Sol_cli_kubectl.apply ~ctx ~file:path with
    | Ok () -> Ok ()
    | Error e ->
      Error
        (Printf.sprintf
           "the workloads were applied and the release recorded, but the deployed \
            consumer groups could not be recorded (configmap default/%s): %s\n\
            The next deploy's consumer-group removal check will not know this deploy's \
            groups; fix access to that ConfigMap and deploy again."
           name
           (Sol_cli_process.error_to_string e)))
  |> Result.join
;;

let record_consumer_groups ~ctx ~workspace groups =
  save_deployed_groups ~ctx workspace groups
;;

let record_outcome ~ctx workspace outcome =
  match outcome with
  | Applied { consumer_groups; _ } ->
    record_consumer_groups ~ctx ~workspace consumer_groups
  | Emitted _ | Dry_run | Failed _ -> Ok ()
;;

let removed_consumer_groups ~prev ~next =
  List.filter (fun g -> not (List.mem g next)) prev
;;

let check_removed_groups ~ctx ~workspace ~confirm_group_change ~next =
  match load_deployed_groups ~ctx workspace with
  | Error msg when confirm_group_change ->
    Sol_cli_report.warn
      "warning: %s\n\
       The consumer-group removal check could not run; proceeding because \
       --confirm-group-change was passed."
      msg;
    Ok ()
  | Error msg ->
    Error
      (Printf.sprintf
         "%s\n\
          The consumer-group removal check cannot run without it. Fix access to that \
          ConfigMap, or pass --confirm-group-change to proceed without the check."
         msg)
  | Ok prev ->
    (match removed_consumer_groups ~prev ~next with
     | _ :: _ as removed when not confirm_group_change ->
       Error (removed_groups_message removed)
     | _ -> Ok ())
;;
