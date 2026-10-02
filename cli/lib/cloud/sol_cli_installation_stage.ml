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
  let owns = Sol_cli_installation.address_in_zone ~zone:address in
  Ok (List.exists owns addresses)
;;

let existing_zone_id ~run ~provider ~domain =
  let argv =
    (Sol_cli_provider_capabilities.capabilities_of provider).installation_zone_lookup
      domain
  in
  match run argv with
  | Sol_cli_installation.Observed output when not (Sol_cli_string.is_blank output) ->
    Ok (Some (String.trim output))
  | Sol_cli_installation.Observed _ | Sol_cli_installation.Absent _ -> Ok None
  | Sol_cli_installation.Unobservable reason ->
    Error
      (Printf.sprintf
         "cannot tell whether a zone for %s already exists (%s), and Sol will not risk \
          creating a second one"
         domain
         reason)
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

type parent_zone =
  | Parent_in_this_account of string
  | Parent_beyond_this_account
  | Parent_unobservable of string

let parent_domain domain =
  match String.split_on_char '.' domain with
  | _ :: (_ :: _ :: _ as rest) -> Some (String.concat "." rest)
  | _ -> None
;;

let parent_zone ~run ~provider ~domain =
  match parent_domain domain with
  | None -> Parent_beyond_this_account
  | Some parent ->
    (match existing_zone_id ~run ~provider ~domain:parent with
     | Ok (Some identity) -> Parent_in_this_account identity
     | Ok None -> Parent_beyond_this_account
     | Error reason -> Parent_unobservable reason)
;;

let delegation_lines ~provider ~domain ~chdir ~known_parent () =
  let parent = Option.value (parent_domain domain) ~default:domain in
  match zone_nameservers ~provider ~chdir with
  | Error message ->
    [ Printf.sprintf "the zone for %s is not observable yet: %s" domain message ]
  | Ok nameservers ->
    (match known_parent with
     | Parent_unobservable reason ->
       [ Printf.sprintf
           "could not tell whether the zone that publishes %s (%s) is in this account \
            (%s), so Sol did not write a delegation it cannot judge"
           domain
           parent
           reason
       ]
     | Parent_in_this_account _ | Parent_beyond_this_account -> [])
    @ [ Printf.sprintf
          "add these NS records for %s at the zone that publishes it (%s):"
          domain
          parent
      ]
    @ List.map (fun nameserver -> Printf.sprintf "  NS  %s" nameserver) nameservers
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

let await_public_delegation
      ~(configuration : Sol_cli_installation.installation_config)
      ~(run : string list -> Sol_cli_installation.observation)
      ~seconds
      ~(report : string -> unit)
      ~(on_established : unit -> (unit, string) result)
  : (unit, string) result
  =
  match
    Sol_cli_installation.zone_domain configuration.Sol_cli_installation.zone, seconds
  with
  | Some domain, seconds when seconds > 0 ->
    let attempts = max 1 (seconds / 5) in
    report "";
    report
      (Printf.sprintf
         "Waiting up to %d seconds for the delegation of %s to appear in public DNS (%d \
          attempt(s)):"
         seconds
         domain
         attempts);
    (match
       await_delegation
         ~run
         ~report:(fun line -> report ("  " ^ line))
         ~attempts
         ~interval:5.
         ~domain
         ()
     with
     | Sol_cli_installation.Established -> on_established ()
     | Sol_cli_installation.Unmet reason | Sol_cli_installation.Unknown reason ->
       Error reason)
  | _, _ -> Ok ()
;;

type contract_file = Sol_cli_provider_capabilities.identity_contract * string

let identity_contract_files ~provider ~configuration : (contract_file list, string) result
  =
  let open Result.Syntax in
  let* backend =
    Sol_cli_provider_capabilities.installation_backend provider configuration
  in
  let dir =
    Filename.concat
      (Sol_cli_terraform_workdir.dir
         ~provider
         ~role:Sol_cli_platform_assets.Bootstrap
         ~backend_config:backend)
      "identity-contracts"
  in
  Ok
    (Sol_cli_provider_capabilities.installation_identity_contracts provider
     |> List.map (fun (contract : Sol_cli_provider_capabilities.identity_contract) ->
       contract, Filename.concat dir (contract.policy_output ^ ".json")))
;;

let write_identity_contracts ~provider ~configuration ~chdir =
  let open Result.Syntax in
  let* files = identity_contract_files ~provider ~configuration in
  match files with
  | [] -> Ok ()
  | (_, first_path) :: _ ->
    let* output =
      Sol_cli_terraform.output_json ~chdir ()
      |> Result.map_error Sol_cli_process.error_to_string
    in
    let* () = Sol_cli_fs.mkdir_p (Filename.dirname first_path) in
    List.fold_left
      (fun accumulated
        ((contract : Sol_cli_provider_capabilities.identity_contract), path) ->
         let* () = accumulated in
         match
           Sol_cli_terraform_outputs.raw output.stdout ~name:contract.policy_output
         with
         | Error message -> Error message
         | Ok None ->
           Error
             (Printf.sprintf
                "the durable root reports no %s output"
                contract.policy_output)
         | Ok (Some document) -> Sol_cli_fs.write_atomic path (document ^ "\n"))
      (Ok ())
      files
;;

let identity_contract_lines ~target ~provider ~configuration ~verdicts =
  let is_unresolved (contract : Sol_cli_provider_capabilities.identity_contract) =
    match List.assoc_opt contract.identity verdicts with
    | Some Sol_cli_installation.Established -> false
    | Some (Sol_cli_installation.Unmet _ | Sol_cli_installation.Unknown _) | None -> true
  in
  let contracts =
    Sol_cli_provider_capabilities.installation_identity_contracts provider
  in
  if not (List.exists is_unresolved contracts)
  then []
  else (
    let locate =
      "  the identity policy contracts are written when the durable root is reconciled; \n\
      \  create each role from its contract and declare its ARN:"
    in
    match identity_contract_files ~provider ~configuration with
    | Error message -> [ locate; Printf.sprintf "    %s" message ]
    | Ok files ->
      let all_written = List.for_all (fun (_, path) -> Sys.file_exists path) files in
      if not all_written
      then [ locate; Printf.sprintf "    sol cloud bootstrap %s --apply" target ]
      else
        [ "  the identities are yours to create: Sol owns each policy contract \n\
          \  (AUDIT-072), you create the role and declare its ARN — Sol looks the role \n\
          \  up by the name in that ARN:"
        ]
        @ List.filter_map
            (fun ((contract : Sol_cli_provider_capabilities.identity_contract), path) ->
               if not (is_unresolved contract)
               then None
               else
                 Some
                   (Printf.sprintf
                      "    %-24s declare %s\n      contract: %s"
                      (Sol_cli_installation.prerequisite_label contract.identity)
                      contract.declared_as
                      path))
            files)
;;

let reconcile ~assets ~provider ~configuration ~run () =
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
  let manage_dns_zone = Sol_cli_installation.owns_the_zone configuration.zone in
  let* installation_lines =
    if not manage_dns_zone
    then Ok []
    else
      let open Result.Syntax in
      let* owned = owns_the_delegated_zone ~provider ~chdir in
      let domain = Sol_cli_installation.zone_domain configuration.zone in
      if owned
      then
        Ok
          [ Printf.sprintf
              "the durable root already owns the zone for %s; nothing to create or adopt"
              (Option.value ~default:"the declared domain" domain)
          ]
      else (
        match domain with
        | None -> Ok []
        | Some domain ->
          let* existing = existing_zone_id ~run ~provider ~domain in
          (match existing with
           | None ->
             Ok
               [ Printf.sprintf
                   "no zone exists for %s yet, so the durable root creates it"
                   domain
               ]
           | Some identity ->
             let* () =
               Sol_cli_terraform.import_
                 ~chdir
                 ~var_files:[]
                 ~vars:
                   (Sol_cli_terraform.kv_args
                      (Sol_cli_provider_capabilities.installation_vars
                         provider
                         ~manage_dns_zone
                         configuration))
                 ~address:
                   (Sol_cli_provider_capabilities.capabilities_of provider)
                     .installation_zone_import_address
                 ~import_identity:identity
                 ()
               |> Result.map (fun _ -> ())
               |> Result.map_error Sol_cli_process.error_to_string
             in
             Ok
               [ Printf.sprintf
                   "a zone for %s already exists and the durable root does not own it: \
                    adopting it (%s) instead of creating a second zone with different \
                    nameservers"
                   domain
                   identity
               ]))
  in
  let* parent =
    match Sol_cli_installation.zone_domain configuration.zone, manage_dns_zone with
    | Some domain, true -> Ok (parent_zone ~run ~provider ~domain)
    | _ -> Ok Parent_beyond_this_account
  in
  let parent_zone_id =
    match parent with
    | Parent_in_this_account identity -> identity
    | Parent_beyond_this_account | Parent_unobservable _ -> ""
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
              ~parent_zone_id
              configuration))
      ()
  in
  let delegation_lines =
    match configuration.Sol_cli_installation.zone with
    | Sol_cli_installation.Service_zone { domain; ownership = Sol_created } ->
      (match parent with
       | Parent_in_this_account identity ->
         [ Printf.sprintf
             "the zone that publishes %s is in this account (%s), so the durable root \
              writes the NS delegation itself: a re-run keeps it, and nothing here needs \
              a registrar"
             domain
             identity
         ]
       | Parent_beyond_this_account | Parent_unobservable _ ->
         delegation_lines ~provider ~domain ~chdir ~known_parent:parent ())
    | Sol_cli_installation.No_zone
    | Sol_cli_installation.Service_zone
        { ownership = User_supplied | Externally_delegated; _ } -> []
  in
  let contract_lines =
    match write_identity_contracts ~provider ~configuration ~chdir with
    | Ok () -> []
    | Error message ->
      [ Printf.sprintf
          "warning: the identity policy contracts could not be written: %s"
          message
      ]
  in
  Ok (installation_lines @ delegation_lines @ contract_lines)
;;
