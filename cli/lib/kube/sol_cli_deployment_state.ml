(** This module owns one independent lifecycle fact: the removal-warning baseline for
    the workspace's consumer groups.

    It is not derivable from release/boundary state. A plan's [consumer_groups] are the
    workspace's declared Kafka-consuming workers, including units a scoped deploy does
    not apply ({!Sol_cli_deployment_plan.derive_consumer_groups}); a recorded release's
    workloads are the applied and retained boundary. The two legitimately differ, so the
    guard that warns before a deploy drops a group compares the new plan's declared
    intent against this record and the record must exist separately.

    The writers leave the baseline for the lifecycle they completed: local [sol up] and
    direct [sol deploy] record the plan's declared intent, while rollback records the
    restored release's applied groups because it restores that boundary. A missing
    record means a first deployment; an unreadable record fails the guard closed unless
    the operator passes [--confirm-group-change]. Neither may be read as an empty or
    successful observation. *)

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
           "the workload operation completed, but the deployed consumer groups could not \
            be recorded (configmap default/%s): %s\n\
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
