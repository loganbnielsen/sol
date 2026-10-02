type outcome =
  | Established
  | Not_declared

let outcome_to_string = function
  | Established -> "the authorization reconciler identity and its fence are established"
  | Not_declared ->
    "the target declares no authorization reconciler trust principal, so no reconciler \
     identity or fence is created"
;;

let capabilities (target : Sol_cli_config.target) =
  Sol_cli_provider_capabilities.capabilities_of target.provider
;;

let declared_trust (target : Sol_cli_config.target) =
  match
    Sol_cli_config.provider_field target (capabilities target).authorization_trust_field
  with
  | Some value when not (Sol_cli_string.is_blank value) -> Some value
  | Some _ | None -> None
;;

let root_vars target = (capabilities target).authorization_root_vars target

let prepare ~assets (target : Sol_cli_config.target) =
  let open Result.Syntax in
  let provider = target.provider in
  let* backend = Sol_cli_cloud_lifecycle.authorization_backend target in
  let* vars = root_vars target in
  let dir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:backend
  in
  let* _ =
    Sol_cli_terraform_workdir.materialize
      ~assets
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:backend
  in
  let* () =
    Sol_cli_terraform.init ~chdir:dir ~backend_config:backend ()
    |> Result.map ignore
    |> Result.map_error Sol_cli_process.error_to_string
  in
  Ok (dir, Sol_cli_terraform.kv_args vars)
;;

let fence ~assets ~run_log ~target =
  match declared_trust target with
  | None -> Ok Not_declared
  | Some _ ->
    let open Result.Syntax in
    let* dir, vars = prepare ~assets target in
    let addresses = (capabilities target).authorization_fence_addresses in
    let* () =
      Sol_cli_run_log.run_phase run_log ~name:"authorization-fence-apply" (fun () ->
        match addresses with
        | first :: rest ->
          Sol_cli_terraform.apply
            ~scope:(Sol_cli_terraform.targets first rest)
            ~chdir:dir
            ~var_files:[]
            ~vars
            ()
        | [] -> Sol_cli_process.completed ~exit_code:0 ~stdout:"" ~stderr:"")
      |> Result.map ignore
      |> Result.map_error Sol_cli_process.error_to_string
    in
    Ok Established
;;

let destroy ~assets ~run_log ~target =
  match declared_trust target with
  | None -> Ok Not_declared
  | Some _ ->
    let open Result.Syntax in
    let* dir, vars = prepare ~assets target in
    let* () =
      Sol_cli_run_log.run_phase run_log ~name:"authorization-destroy" (fun () ->
        Sol_cli_terraform.destroy ~chdir:dir ~var_files:[] ~vars ())
      |> Result.map ignore
      |> Result.map_error Sol_cli_process.error_to_string
    in
    Ok Established
;;
