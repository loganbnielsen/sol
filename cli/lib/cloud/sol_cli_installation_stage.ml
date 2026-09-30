let durable_root_policy : Sol_cli_terraform_plan.policy =
  let open Sol_cli_terraform_plan in
  { phase = "installation-bootstrap"
  ; rules =
      [ { matches = [ Every_change ]
        ; allows = [ Create; Update; Read; No_op ]
        ; reason =
            "everything this durable root declares outlives every environment, so its \
             metadata may change while recreating or deleting one silently breaks the \
             installation: a recreated DNS zone gets different nameservers than the \
             registrar delegation names, and a recreated bucket is the state store of \
             every other root"
        }
      ]
  }
;;

let state_addresses ~chdir : (string list, string) result =
  let open Result.Syntax in
  let* output =
    Sol_cli_terraform.state_list ~chdir ()
    |> Result.map_error Sol_cli_process.error_to_string
  in
  Ok
    (output.stdout
     |> String.split_on_char '\n'
     |> List.map String.trim
     |> List.filter (fun address -> address <> ""))
;;

let owns_the_delegated_zone ~provider ~chdir =
  let open Result.Syntax in
  let address =
    (Sol_cli_provider_capabilities.capabilities_of provider).installation_zone_address
  in
  let* addresses = state_addresses ~chdir in
  Ok
    (List.exists (fun listed -> Sol_cli_string.contains ~needle:address listed) addresses)
;;

let reconcile ~assets ~provider ~configuration () =
  let open Result.Syntax in
  let run_log = Sol_cli_run_log.create ~prefix:"installation-bootstrap" () in
  let* backend_config =
    Sol_cli_provider_capabilities.installation_backend provider configuration
  in
  let chdir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Bootstrap
      ~backend_config
  in
  let* () =
    Sol_cli_cloud_wiring.credentials_result
      ~provider
      ~operation:"reconciling the durable installation for"
      ~leaves_target_standing:true
  in
  let* () =
    Sol_cli_state_guard.check
      ~constructive:true
      ~accept_unresolved:false
      ~chdir
      ~backend_config
  in
  let* () =
    Sol_cli_cloud_wiring.init_result
      ~assets
      run_log
      ~provider
      ~role:Sol_cli_platform_assets.Bootstrap
      backend_config
  in
  let* manage_dns_zone =
    if Sol_cli_installation.owns_the_zone configuration.zone
    then owns_the_delegated_zone ~provider ~chdir
    else Ok false
  in
  Sol_cli_terraform_steps.apply_asserted
    ~run_log
    ~phase_name:"installation-bootstrap"
    ~policy:durable_root_policy
    ~scope:Sol_cli_terraform.whole_root
    ~chdir
    ~var_files:[]
    ~vars:
      (Sol_cli_terraform.kv_args
         (Sol_cli_provider_capabilities.installation_vars
            provider
            ~manage_dns_zone
            configuration))
    ()
;;
