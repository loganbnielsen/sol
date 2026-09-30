let projection_dir ~workspace = Filename.concat workspace "contract"
let has_projection ~workspace = Sys.file_exists (projection_dir ~workspace)

type mode =
  | Check
  | Apply
  | Projection

let mode_arg = function
  | Check -> "--check"
  | Apply -> "--apply"
  | Projection -> "--json"
;;

let run ~echo ~workspace ~registry_url ~mode =
  if not (has_projection ~workspace)
  then Ok None
  else (
    let cmd =
      Sol_cli_process.cmd
        ~cwd:workspace
        ~env:[ "SCHEMA_REGISTRY_URL", registry_url ]
        ~timeout_s:300.
        [ "dune"; "exec"; "./contract/contract.exe"; "--"; mode_arg mode ]
    in
    match Sol_cli_process.run ~echo cmd with
    | Ok out -> Ok (Some out.stdout)
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let report ~workspace ~registry_url ~mode =
  match run ~echo:true ~workspace ~registry_url ~mode with
  | Error msg -> Error msg
  | Ok None -> Ok ()
  | Ok (Some output) ->
    let trimmed = String.trim output in
    if trimmed <> "" then Sol_cli_report.app "%s" trimmed;
    Ok ()
;;

let print_declared_contract json =
  let string_field fields name =
    match List.assoc_opt name fields with
    | Some (`String value) -> value
    | _ -> "?"
  in
  let int_field fields name =
    match List.assoc_opt name fields with
    | Some (`Int value) -> string_of_int value
    | _ -> "?"
  in
  match Yojson.Safe.from_string json with
  | `Assoc fields ->
    (match List.assoc_opt "events" fields with
     | Some (`List events) ->
       List.iter
         (fun event ->
            match event with
            | `Assoc fields ->
              Sol_cli_report.app
                "  - %s  topic %s  partitions %s\n"
                (string_field fields "module")
                (string_field fields "topic")
                (int_field fields "partitions")
            | _ -> ())
         events
     | _ -> ())
  | _ -> ()
  | exception _ -> ()
;;

let plan_report ~workspace ~registry_url =
  if not (has_projection ~workspace)
  then Ok ()
  else (
    let registry_url = Option.value registry_url ~default:"" in
    (match run ~echo:false ~workspace ~registry_url ~mode:Projection with
     | Error msg ->
       Sol_cli_report.warn "warning: could not project the declared contract: %s" msg
     | Ok None -> ()
     | Ok (Some json) ->
       Sol_cli_report.app "\nContract (declared):";
       print_declared_contract json);
    (match registry_url with
     | "" ->
       Sol_cli_report.app
         "  registry: not observed (no SCHEMA_REGISTRY_URL; a private registry is only \
          reachable from the destination, and `sol deploy` reconciles it there)\n"
     | registry_url ->
       (match run ~echo:false ~workspace ~registry_url ~mode:Check with
        | Ok (Some output) ->
          String.split_on_char '\n' output
          |> List.iter (fun line ->
            let line = String.trim line in
            if line <> "" then Sol_cli_report.app "  %s" line)
        | Ok None -> ()
        | Error msg -> Sol_cli_report.app "  registry: not observed -- %s" msg));
    Ok ())
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
