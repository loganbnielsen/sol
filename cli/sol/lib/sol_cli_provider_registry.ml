(* The second half of the provider registry: which provider module builds the
   cluster a cloud root produced (REFAC-096) and a destroy's retention and residue
   (REFAC-097). [Sol_cli_provider_capabilities] holds the table-shaped capabilities
   and sits below the lifecycle; these modules depend on the lifecycle, so their
   selection lives one layer up. Exhaustive and wildcard-free, like
   [capabilities_of]. *)

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

(* The cloud root's cluster, read from `terraform output -json`. [None] when the
   root has no outputs yet: no substrate. *)
let of_root provider ~target ~chdir =
  let { label; build } = builder provider ~target in
  match Sol_cli_terraform.output_json ~chdir () with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    (match Yojson.Safe.from_string result.stdout with
     | `Assoc [] -> Ok None
     | _ -> Result.map Option.some (build result.stdout)
     | exception Yojson.Json_error message ->
       Error (Printf.sprintf "invalid %s Terraform output JSON: %s" label message))
  | Ok result ->
    Error (Printf.sprintf "terraform output failed with exit %d" result.exit_code)
  | Error _ -> Error (Printf.sprintf "could not read %s Terraform outputs" label)
;;

let destruction provider context =
  match provider with
  | Sol_cli_provider.Aws -> Sol_cli_aws_destruction.destruction context
  | Sol_cli_provider.Gcp -> Sol_cli_gcp_destruction.destruction context
;;
