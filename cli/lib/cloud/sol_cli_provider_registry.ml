type builder =
  { label : string
  ; identifying_resources : string list
  ; build : string -> (Sol_cli_cluster.t, string) result
  }

let builder provider ~(target : Sol_cli_config.target) =
  let region = target.region in
  let of_json of_outputs_json cluster text = Result.map cluster (of_outputs_json text) in
  match provider with
  | Sol_cli_provider.Aws ->
    { label = Sol_cli_aws_cluster.label
    ; identifying_resources = [ "module.eks.aws_eks_cluster" ]
    ; build =
        of_json
          Sol_cli_aws_cluster.of_outputs_json
          (Sol_cli_aws_cluster.cluster
             ~region
             ~provisioner_role_arn:
               (Sol_cli_config.provider_field target "provisioner_role_arn")
             ~deploy_role_arn:(Sol_cli_config.provider_field target "deploy_role_arn"))
    }
  | Sol_cli_provider.Gcp ->
    { label = Sol_cli_gcp_cluster.label
    ; identifying_resources = [ "google_container_cluster.main" ]
    ; build =
        of_json Sol_cli_gcp_cluster.of_outputs_json (Sol_cli_gcp_cluster.cluster ~region)
    }
;;

type resolution_failure =
  | Outputs_unreadable of string
  | State_unreadable of string

let resolution_failure_to_string = function
  | Outputs_unreadable message | State_unreadable message -> message
;;

let state_holds_any ~chdir prefixes =
  match Sol_cli_terraform.state_list ~chdir () with
  | Ok result ->
    Ok
      (result.stdout
       |> String.split_on_char '\n'
       |> List.exists (fun line ->
         let line = String.trim line in
         List.exists
           (fun prefix ->
              String.length line >= String.length prefix
              && String.sub line 0 (String.length prefix) = prefix)
           prefixes))
  | Error (Sol_cli_process.Non_zero result) ->
    Error
      (State_unreadable
         (Printf.sprintf "terraform state list failed with exit %d" result.exit_code))
  | Error error ->
    Error
      (State_unreadable
         ("could not read the Terraform state listing: "
          ^ Sol_cli_process.error_to_string error))
;;

let of_root provider ~target ~chdir =
  let { label; identifying_resources; build } = builder provider ~target in
  let cluster_of_outputs text = Result.map Option.some (build text) in
  match Sol_cli_terraform.output_json ~chdir () with
  | Ok result ->
    (match Yojson.Safe.from_string result.stdout with
     | `Assoc _ ->
       (match state_holds_any ~chdir identifying_resources with
        | Error failure -> Error failure
        | Ok false -> Ok None
        | Ok true ->
          cluster_of_outputs result.stdout
          |> Result.map_error (fun message -> Outputs_unreadable message))
     | _ ->
       cluster_of_outputs result.stdout
       |> Result.map_error (fun message -> Outputs_unreadable message)
     | exception Yojson.Json_error message ->
       Error
         (Outputs_unreadable
            (Printf.sprintf "invalid %s Terraform output JSON: %s" label message)))
  | Error (Sol_cli_process.Non_zero result) ->
    Error
      (Outputs_unreadable
         (Printf.sprintf "terraform output failed with exit %d" result.exit_code))
  | Error e ->
    Error
      (Outputs_unreadable
         (Printf.sprintf
            "could not read %s Terraform outputs: %s"
            label
            (Sol_cli_process.error_to_string e)))
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
