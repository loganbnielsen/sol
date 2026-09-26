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

(* BUG-025: the name embeds the workspace, and '_' or uppercase are illegal in
   a Kubernetes object name — so a workspace like [ci_smoke] produced
   "sol-deploy-state-ci_smoke", which the API server rejects. Because the apply
   result used to be ignored below, that failure was silent. *)
let deploy_state_configmap_name workspace =
  Printf.sprintf "sol-deploy-state-%s" (Sol_cli_kubernetes_name.sanitize_name workspace)
;;

(* FEAT-063: the state ConfigMap lives in the cluster the target names, so every
   entry point takes the destination-side context and passes it to kubectl. *)
let load_deployed_groups ~ctx workspace =
  let name = deploy_state_configmap_name workspace in
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:"configmap"
      ~name
      ~namespace:"default"
      ~output:"jsonpath={.data.consumer_groups}"
  with
  | Ok r ->
    Ok
      (String.split_on_char '\n' r.Sol_cli_process.stdout
       |> List.map String.trim
       |> List.filter (fun s -> s <> ""))
  (* BUG-045 / FND-0038: only "no record yet" (a first deploy) means no previous
     groups. Any other failure used to read the same way, so the removal guard
     passed silently exactly when the cluster could not be asked. *)
  | Error (Sol_cli_process.Non_zero { stderr; _ })
    when Sol_cli_string.contains ~needle:"NotFound" stderr -> Ok []
  | Error e ->
    Error
      (Printf.sprintf
         "could not read the recorded consumer groups (configmap default/%s): %s"
         name
         (Sol_cli_process.error_to_string e))
;;

(* The hazard the removal guard exists for, stated for Sol's own consumers:
   they all use [offset_reset = Earliest]. *)
let removed_groups_message removed =
  String.concat
    ""
    [ "\n\
       error: the following consumer group(s) are no longer present in this deploy plan:\n"
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
    Printf.sprintf
      {|{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","namespace":"default"},"data":{"consumer_groups":"%s"}}|}
      (String.escaped name)
      (String.escaped value)
  in
  let path = Filename.temp_file "sol-state-" ".json" in
  let oc = open_out path in
  output_string oc apply_json;
  close_out oc;
  (* BUG-025 reported a failed write; BUG-045 makes it an error. The next deploy's
     consumer-group removal check reads this record, so a failed write is a
     deploy whose safety check the next deploy cannot run. *)
  let result =
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
           (Sol_cli_process.error_to_string e))
  in
  (try Sys.remove path with
   | Sys_error _ -> ());
  result
;;

let record_outcome ~ctx workspace outcome =
  match outcome with
  | Applied { consumer_groups; _ } -> save_deployed_groups ~ctx workspace consumer_groups
  | Emitted _ | Dry_run | Failed _ -> Ok ()
;;

let removed_consumer_groups ~prev ~next =
  List.filter (fun g -> not (List.mem g next)) prev
;;

(* The consumer-group removal guard shared by [sol deploy] and [sol up]. An
   unreadable record is not "no previous groups" (BUG-045): it refuses unless the
   operator already acknowledges group changes, in which case it warns. *)
let check_removed_groups ~ctx ~workspace ~confirm_group_change ~next =
  match load_deployed_groups ~ctx workspace with
  | Error msg when confirm_group_change ->
    Printf.eprintf
      "warning: %s\n\
       The consumer-group removal check could not run; proceeding because \
       --confirm-group-change was passed.\n\
       %!"
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
