type builder =
  { label : string
  ; build : string -> (Sol_cli_cluster.t, string) result
  }

let builder provider ~(target : Sol_cli_config.target) =
  let region = target.region in
  let of_json of_outputs_json cluster text = Result.map cluster (of_outputs_json text) in
  match provider with
  | Sol_cli_provider.Aws ->
    { label = Sol_cli_aws_cluster.label
    ; build =
        of_json
          Sol_cli_aws_cluster.of_outputs_json
          (Sol_cli_aws_cluster.cluster
             ~region
             ~provisioner_role_arn:
               (Sol_cli_config.provider_field target "provisioner_role_arn"))
    }
  | Sol_cli_provider.Gcp ->
    { label = Sol_cli_gcp_cluster.label
    ; build =
        of_json Sol_cli_gcp_cluster.of_outputs_json (Sol_cli_gcp_cluster.cluster ~region)
    }
;;

let of_root provider ~target ~chdir =
  let { label; build } = builder provider ~target in
  match Sol_cli_terraform.output_json ~chdir () with
  | Ok result ->
    (match Yojson.Safe.from_string result.stdout with
     | `Assoc [] -> Ok None
     | _ -> Result.map Option.some (build result.stdout)
     | exception Yojson.Json_error message ->
       Error (Printf.sprintf "invalid %s Terraform output JSON: %s" label message))
  | Error (Sol_cli_process.Non_zero result) ->
    Error (Printf.sprintf "terraform output failed with exit %d" result.exit_code)
  | Error e ->
    Error
      (Printf.sprintf
         "could not read %s Terraform outputs: %s"
         label
         (Sol_cli_process.error_to_string e))
;;

let destruction provider context =
  match provider with
  | Sol_cli_provider.Aws -> Sol_cli_aws_destruction.destruction context
  | Sol_cli_provider.Gcp -> Sol_cli_gcp_destruction.destruction context
;;

let observations provider target ~cluster_name =
  match provider with
  | Sol_cli_provider.Aws -> Sol_cli_aws_absence.observations target ~cluster_name
  | Sol_cli_provider.Gcp -> Sol_cli_gcp_absence.observations target ~cluster_name
;;

let resource_identity provider ~cluster_name =
  match provider with
  | Sol_cli_provider.Aws -> Sol_cli_resource_identity.aws ~cluster_name
  | Sol_cli_provider.Gcp -> Sol_cli_resource_identity.gcp ~cluster_name
;;

let credentials provider ~operation ~leaves_target_standing =
  match provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_cluster.credentials ~operation ~leaves_target_standing
  | Sol_cli_provider.Gcp ->
    Sol_cli_gcp_cluster.credentials ~operation ~leaves_target_standing
;;
