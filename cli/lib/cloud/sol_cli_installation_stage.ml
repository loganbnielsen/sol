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

let zone_nameservers ~provider ~chdir : (string list, string) result =
  let open Result.Syntax in
  let output_name =
    Sol_cli_provider_capabilities.installation_nameservers_output provider
  in
  let* output =
    Sol_cli_terraform.output_json ~chdir ()
    |> Result.map_error Sol_cli_process.error_to_string
  in
  let* outputs = Sol_cli_terraform_outputs.displayable output.stdout in
  match List.assoc_opt output_name outputs with
  | Some (Sol_cli_terraform_outputs.Texts nameservers) -> Ok nameservers
  | Some (Sol_cli_terraform_outputs.Text nameserver) -> Ok [ nameserver ]
  | Some Sol_cli_terraform_outputs.Null | None ->
    Error
      (Printf.sprintf
         "the durable root reports no %s, so the zone is not created yet"
         output_name)
;;

let print_delegation_instruction ~provider ~domain ~chdir () =
  let parent =
    match String.split_on_char '.' domain with
    | _ :: (_ :: _ as rest) -> String.concat "." rest
    | _ -> domain
  in
  match zone_nameservers ~provider ~chdir with
  | Error message ->
    Printf.printf "\nThe zone for %s is not observable yet: %s.\n%!" domain message
  | Ok nameservers ->
    Printf.printf
      "\n\
       One action is required at the zone that publishes %s (%s): add these NS records \
       for %s,\n\
       or let the durable root create the delegation when that zone is in this account.\n\
       %!"
      domain
      parent
      domain;
    List.iter (fun nameserver -> Printf.printf "  NS  %s\n%!" nameserver) nameservers
;;

let await_delegation ~run ~report ~attempts ~interval ~domain ?(expected = []) () =
  let satisfies = function
    | Sol_cli_installation.Observed output ->
      (match expected with
       | [] -> not (Sol_cli_string.is_blank output)
       | nameservers ->
         List.for_all
           (fun nameserver -> Sol_cli_string.contains ~needle:nameserver output)
           nameservers)
    | Sol_cli_installation.Absent _ | Sol_cli_installation.Unobservable _ -> false
  in
  let describe = function
    | Sol_cli_installation.Observed output ->
      if Sol_cli_string.is_blank output then "no NS records yet" else String.trim output
    | Sol_cli_installation.Absent reason | Sol_cli_installation.Unobservable reason ->
      reason
  in
  let rec go attempt =
    match run [ "dig"; "+short"; "NS"; domain ] with
    | Sol_cli_installation.Unobservable reason -> Sol_cli_installation.Unknown reason
    | observed ->
      if satisfies observed
      then Sol_cli_installation.Established
      else (
        let reached_the_limit = attempt >= attempts in
        report
          (Printf.sprintf
             "%s %s (%d/%d): the resolver answers %s"
             (if reached_the_limit
              then "gave up waiting for the delegation to"
              else "waiting for the delegation to")
             domain
             attempt
             attempts
             (describe observed));
        match observed with
        | _ when reached_the_limit ->
          Sol_cli_installation.Unmet
            (Printf.sprintf
               "after %d attempt(s) the resolver answers %s for %s"
               attempts
               (describe observed)
               domain)
        | _ ->
          Unix.sleepf interval;
          go (attempt + 1))
  in
  if attempts <= 0
  then
    Sol_cli_installation.Unmet
      (Printf.sprintf "no delegation wait was requested for %s" domain)
  else go 1
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
  let* () =
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
  in
  match configuration.Sol_cli_installation.zone with
  | Sol_cli_installation.Service_zone { domain; ownership = Sol_created } ->
    print_delegation_instruction ~provider ~domain ~chdir ();
    Ok ()
  | Sol_cli_installation.No_zone
  | Sol_cli_installation.Service_zone
      { ownership = User_supplied | Externally_delegated; _ } -> Ok ()
;;
