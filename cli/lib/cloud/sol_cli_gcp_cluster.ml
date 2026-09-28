open Result.Syntax

type gcp_outputs =
  { cluster_name : string
  ; project_id : string
  ; region : string
  ; artifact_registry : string
  ; loki_gcs_bucket : string option
  ; loki_workload_identity_sa_email : string option
  ; thanos_gcs_bucket : string option
  ; thanos_workload_identity_sa_email : string option
  ; cert_manager_workload_identity_sa_email : string option
  ; provisioner_service_account : string
  }

let gcp_outputs_of_json text =
  let open Result.Syntax in
  let* _, string, optional_string = Sol_cli_cluster.outputs_reader ~provider:"GCP" text in
  let* cluster_name = string "cluster_name" in
  let* project_id = string "project_id" in
  let* region = string "region" in
  let* artifact_registry = string "artifact_registry" in
  let* loki_gcs_bucket = optional_string "loki_gcs_bucket" in
  let* loki_workload_identity_sa_email =
    optional_string "loki_workload_identity_sa_email"
  in
  let* thanos_gcs_bucket = optional_string "thanos_gcs_bucket" in
  let* thanos_workload_identity_sa_email =
    optional_string "thanos_workload_identity_sa_email"
  in
  let* cert_manager_workload_identity_sa_email =
    optional_string "cert_manager_workload_identity_sa_email"
  in
  let* provisioner_service_account = string "provisioner_service_account" in
  Ok
    { cluster_name
    ; project_id
    ; region
    ; artifact_registry
    ; loki_gcs_bucket
    ; loki_workload_identity_sa_email
    ; thanos_gcs_bucket
    ; thanos_workload_identity_sa_email
    ; cert_manager_workload_identity_sa_email
    ; provisioner_service_account
    }
;;

let gcp_platform_toolchain_result () : (unit, string) result =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "gke-gcloud-auth-plugin"; "--version" ])
  with
  | Ok _ -> Ok ()
  | _ ->
    Error
      "the platform cannot reach a GKE cluster without `gke-gcloud-auth-plugin`, which \
       is not on PATH: the kubeconfig gcloud writes names it as its credential plugin, \
       so every Kubernetes call would fail with \"executable gke-gcloud-auth-plugin not \
       found\". Install it (`gcloud components install gke-gcloud-auth-plugin`) and \
       re-run. Nothing has been changed."
;;

let gcp_provisioner_kubeconfig_result
      ~region
      outputs
      (f : env:(string * string) list -> ('a, string) result)
  : ('a, string) result
  =
  let* () = gcp_platform_toolchain_result () in
  let path = Filename.temp_file "sol-platform-provisioner-" ".kubeconfig" in
  let cleanup () = Sol_cli_fs.remove_reporting path in
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
    let env = Sol_cli_cluster.provisioner_kube_env path in
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           ~env
           [ "gcloud"
           ; "container"
           ; "clusters"
           ; "get-credentials"
           ; outputs.cluster_name
           ; "--region"
           ; region
           ; "--project"
           ; outputs.project_id
           ; "--impersonate-service-account"
           ; outputs.provisioner_service_account
           ; "--quiet"
           ])
    with
    | Ok _ -> f ~env
    | Error (Sol_cli_process.Non_zero result) ->
      Error
        (Printf.sprintf
           "could not establish ephemeral cluster access as %s: gcloud exited %d%s"
           outputs.provisioner_service_account
           result.exit_code
           (let detail = String.trim result.stderr in
            if detail = "" then "" else ":\n" ^ detail))
    | Error error ->
      Error
        (Printf.sprintf
           "could not run gcloud to establish cluster access: %s"
           (Sol_cli_process.error_to_string error)))
;;

let gcp_cloud_ready outputs =
  let project = outputs.project_id in
  let region = outputs.region in
  let cluster = outputs.cluster_name in
  let status argv = Sol_cli_cluster.process_output ([ "gcloud" ] @ argv) in
  match
    ( status
        [ "container"
        ; "clusters"
        ; "describe"
        ; cluster
        ; "--region"
        ; region
        ; "--project"
        ; project
        ; "--format"
        ; "value(status)"
        ]
    , status
        [ "sql"
        ; "instances"
        ; "describe"
        ; cluster ^ "-postgres"
        ; "--project"
        ; project
        ; "--format"
        ; "value(state)"
        ] )
  with
  | Some cluster_status, Some sql_state
    when String.trim cluster_status = "RUNNING" && String.trim sql_state = "RUNNABLE" ->
    true
  | _ -> false
;;

let platform_vars outputs _context ~cluster_issuer:_ ~region:_ =
  Ok
    { Sol_cli_cluster.fixed = [ "cloud_provider=gcp"; "storage_class_name=standard-rwo" ]
    ; optional =
        [ "loki_gcs_bucket", outputs.loki_gcs_bucket
        ; "loki_workload_identity_sa_email", outputs.loki_workload_identity_sa_email
        ; "thanos_gcs_bucket", outputs.thanos_gcs_bucket
        ; "thanos_workload_identity_sa_email", outputs.thanos_workload_identity_sa_email
        ; ( "cert_manager_workload_identity_sa_email"
          , outputs.cert_manager_workload_identity_sa_email )
        ; "cert_manager_dns01_project", Some outputs.project_id
        ; "gcp_provisioner_service_account", Some outputs.provisioner_service_account
        ]
    }
;;

let label = "GCP"
let of_outputs_json = gcp_outputs_of_json

let cluster ~region outputs : Sol_cli_cluster.t =
  { name = outputs.cluster_name
  ; check_identity = (fun ~cluster_access_role_arn:_ -> Ok ())
  ; platform_vars = platform_vars outputs
  ; with_access = (fun f -> gcp_provisioner_kubeconfig_result ~region outputs f)
  ; ready = (fun () -> gcp_cloud_ready outputs)
  ; bootstrap_window = Sol_cli_cluster.Closed_by_platform_root
  }
;;

let credentials ~operation ~leaves_target_standing : (unit, string) result =
  let standing_remark =
    if leaves_target_standing
    then
      " The target is still standing and may still be billing; nothing has been changed."
    else " Nothing has been changed."
  in
  match
    Sol_cli_cluster.process_output
      [ "gcloud"; "auth"; "application-default"; "print-access-token" ]
  with
  | Some _ ->
    Sol_cli_report.app "  credentials: Google Application Default Credentials resolved";
    Ok ()
  | None ->
    Error
      (Printf.sprintf
         "cannot resolve Google Application Default Credentials, so Sol cannot \
          %s              this target.%s Run `gcloud auth application-default login` (or \
          fix the              attached service account) and re-run."
         operation
         standing_remark)
;;

let project_id_of_outputs_json text : (string, string) result =
  Sol_cli_cluster.outputs_reader ~provider:"GCP" text
  |> Fun.flip Result.bind (fun (_raw, string, _optional_string) -> string "project_id")
;;

let disk_quota ~outputs_json ~region : (Sol_cli_disk_quota.observation, string) result =
  let open Result.Syntax in
  let* project = project_id_of_outputs_json outputs_json in
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "gcloud"
         ; "compute"
         ; "regions"
         ; "describe"
         ; region
         ; "--project"
         ; project
         ; "--format=json"
         ])
  with
  | Ok result -> Sol_cli_disk_quota.observation_of_json result.stdout
  | Error error ->
    Error
      (Printf.sprintf
         "could not read the disk quota of region %s in project %s: %s"
         region
         project
         (Sol_cli_process.error_to_string error))
;;

let autopilot_of_describe_json text : (bool, string) result =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error message ->
    Error (Printf.sprintf "the describe output is not JSON: %s" message)
  | json ->
    Sol_cli_json.field [ "autopilot"; "enabled" ] json
    |> Sol_cli_json.bool
    |> Option.to_result ~none:"the cluster describe carries no autopilot.enabled field"
;;

let substrate_of_describe ~outputs_json ~region ~cluster_name
  : (Sol_cli_cluster_substrate.t, string) result
  =
  let open Sol_cli_cluster_substrate in
  let project =
    match project_id_of_outputs_json outputs_json with
    | Ok project -> project
    | Error _ -> ""
  in
  if project = ""
  then Ok (Unknown "the cloud root's outputs carry no project to read the cluster from")
  else (
    let cmd =
      Sol_cli_process.cmd
        [ "gcloud"
        ; "container"
        ; "clusters"
        ; "describe"
        ; cluster_name
        ; "--region"
        ; region
        ; "--project"
        ; project
        ; "--format=json(autopilot.enabled)"
        ]
    in
    match Sol_cli_process.run ~echo:false cmd with
    | Ok output ->
      (match autopilot_of_describe_json output.Sol_cli_process.stdout with
       | Ok true -> Ok Autopilot
       | Ok false -> Ok Standard
       | Error message -> Ok (Unknown message))
    | Error (Sol_cli_process.Non_zero failure) ->
      let said =
        String.trim (failure.Sol_cli_process.stderr ^ failure.Sol_cli_process.stdout)
      in
      if Sol_cli_gcloud.says_not_found said
      then Ok Absent
      else
        Ok
          (Unknown
             (if said = ""
              then
                Printf.sprintf
                  "the provider reported exit %d"
                  failure.Sol_cli_process.exit_code
              else said))
    | Error error -> Ok (Unknown (Sol_cli_process.error_to_string error)))
;;
