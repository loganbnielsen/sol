open Result.Syntax

let projection_dir ~workspace = Filename.concat workspace "contract"
let entry_point ~workspace = Filename.concat (projection_dir ~workspace) "run"
let has_projection ~workspace = Sys.file_exists (entry_point ~workspace)

type mode =
  | Check
  | Apply
  | Projection

let mode_arg = function
  | Check -> "--check"
  | Apply -> "--apply"
  | Projection -> "--json"
;;

let run ~echo ~workspace ~registry_url ~scope ~mode =
  if not (has_projection ~workspace)
  then Ok None
  else (
    let cmd =
      Sol_cli_process.cmd
        ~cwd:workspace
        ~env:[ "SCHEMA_REGISTRY_URL", registry_url ]
        ~timeout_s:300.
        [ "sh"; "./contract/run"; mode_arg mode; "--scope"; scope ]
    in
    match Sol_cli_process.run ~echo cmd with
    | Ok out -> Ok (Some out.stdout)
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let report ~workspace ~registry_url ~scope ~mode =
  match run ~echo:true ~workspace ~registry_url ~scope ~mode with
  | Error msg -> Error msg
  | Ok None -> Ok ()
  | Ok (Some output) ->
    let trimmed = String.trim output in
    if trimmed <> "" then Sol_cli_report.app "%s" trimmed;
    Ok ()
;;

type declared_event =
  { module_name : string
  ; topic : string
  ; partitions : int
  }

let decode_declared_contract json : (declared_event list, string) result =
  let* payload = Sol_cli_json.decode ~what:"the declared contract" json in
  let* events =
    Sol_cli_json.require
      ~what:"the declared contract"
      [ "events" ]
      Sol_cli_json.list
      payload
  in
  Sol_cli_result.map_list
    (fun event ->
       let* module_name =
         Sol_cli_json.require
           ~what:"a declared event"
           [ "module" ]
           Sol_cli_json.string
           event
       in
       let* topic =
         Sol_cli_json.require
           ~what:"a declared event"
           [ "topic" ]
           Sol_cli_json.string
           event
       in
       let* partitions =
         Sol_cli_json.require
           ~what:"a declared event"
           [ "partitions" ]
           Sol_cli_json.int
           event
       in
       Ok { module_name; topic; partitions })
    events
;;

let print_declared_contract events =
  List.iter
    (fun { module_name; topic; partitions } ->
       Sol_cli_report.app "  - %s  topic %s  partitions %d\n" module_name topic partitions)
    events
;;

let plan_report ~workspace ~registry_url ~scope =
  if not (has_projection ~workspace)
  then Ok ()
  else (
    let registry_url = Option.value registry_url ~default:"" in
    (match run ~echo:false ~workspace ~registry_url ~scope ~mode:Projection with
     | Error msg ->
       Sol_cli_report.warn "warning: could not project the declared contract: %s" msg
     | Ok None -> ()
     | Ok (Some json) ->
       (match decode_declared_contract json with
        | Ok events ->
          Sol_cli_report.app "\nContract (declared):";
          print_declared_contract events
        | Error reason ->
          Sol_cli_report.warn "warning: could not read the declared contract: %s" reason));
    (match registry_url with
     | "" ->
       Sol_cli_report.app
         "  registry: not observed (no SCHEMA_REGISTRY_URL; a private registry is only \
          reachable from the destination, and `sol deploy` reconciles it there)\n"
     | registry_url ->
       (match run ~echo:false ~workspace ~registry_url ~scope ~mode:Check with
        | Ok (Some output) ->
          String.split_on_char '\n' output
          |> List.iter (fun line ->
            let line = String.trim line in
            if line <> "" then Sol_cli_report.app "  %s" line)
        | Ok None -> ()
        | Error msg -> Sol_cli_report.app "  registry: not observed -- %s" msg));
    Ok ())
;;

let reconciliation_images services =
  let seen = ref [] in
  List.filter_map
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       if List.mem spec.Sol_cli_deployment_plan.language !seen
       then None
       else (
         seen := spec.Sol_cli_deployment_plan.language :: !seen;
         Some
           ( Sol_cli_deployment_plan.namespace_to_string
               spec.Sol_cli_deployment_plan.namespace
           , spec.Sol_cli_deployment_plan.image )))
    services
;;

let reconcile_in_destination ~ctx ~namespace ~image =
  match
    Sol_cli_migration_job.submit_doc
      ~ctx
      ~namespace
      ~name_prefix:"sol-contract"
      ~label:"contract"
      (fun ~name ->
         Sol_cli_manifest.contract_job_doc
           ~name
           ~namespace
           ~image
           ~command:[ "/usr/local/bin/contract" ]
           ~args:[ "--apply" ])
  with
  | Error e -> Error ("could not start the contract reconciliation Job: " ^ e)
  | Ok job ->
    (match Sol_cli_migration_job.wait ~ctx ~interval_s:2. ~attempts:150 job with
     | Succeeded ->
       Sol_cli_migration_job.cleanup ~ctx job;
       Sol_cli_report.app "Contract: reconciled in the destination with image %s." image;
       Ok ()
     | Failed ->
       Sol_cli_migration_job.evidence ~ctx job
       |> Option.iter (Sol_cli_report.err "\ncontract reconciliation Job evidence:\n%s");
       Error
         (Printf.sprintf
            "the contract reconciliation Job failed; it is kept for inspection:\n\
            \  kubectl logs job/%s -n %s\n\
             No workload was rolled out."
            job.job_name
            namespace)
     | Unstartable { reason; detail } ->
       Sol_cli_migration_job.evidence ~ctx job
       |> Option.iter (Sol_cli_report.err "\ncontract reconciliation Job evidence:\n%s");
       Error
         (Printf.sprintf
            "the contract reconciliation Job could not start (%s%s); it is kept for \
             inspection:\n\
            \  kubectl logs job/%s -n %s\n\
             No workload was rolled out."
            reason
            (match detail with
             | Some detail -> ": " ^ detail
             | None -> "")
            job.job_name
            namespace)
     | Timed_out seconds ->
       Error
         (Printf.sprintf
            "the contract reconciliation Job did not finish within %.0fs; it is kept for \
             inspection:\n\
            \  kubectl logs job/%s -n %s\n\
             No workload was rolled out."
            seconds
            job.job_name
            namespace))
;;
