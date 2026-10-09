open Cmdliner
open Result.Syntax

let retained_lines (plan : Sol_cli_installation_uninstall.plan) =
  match plan.retains with
  | [] -> [ "  nothing" ]
  | retains -> List.map (fun (what, why) -> Printf.sprintf "  %s -- %s" what why) retains
;;

let print_retained plan =
  Printf.printf "\nRetained:\n%s\n%!" (String.concat "\n" (retained_lines plan))
;;

let uninstall ~target ~var_file ~vars ~confirm ~confirm_dns_zone () =
  let* () = Cmd_cloud_tf.check_terraform () in
  let* provider = Cmd_cloud_tf.provider_of_target_path target in
  let* target_cfg = Cmd_cloud_tf.declared_target target in
  let* configuration = Sol_cli_installation.of_target target_cfg |> Sol_cli_exit.of_msg in
  let* assets = Cmd_cloud_tf.resolve_assets () in
  let* backend =
    Sol_cli_provider_capabilities.installation_backend provider configuration
    |> Sol_cli_exit.of_msg
  in
  let capabilities = Sol_cli_provider_capabilities.capabilities_of provider in
  let run_log = Sol_cli_run_log.create ~prefix:"installation-uninstall" () in
  let chdir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Bootstrap
      ~backend_config:backend
  in
  let* () =
    Sol_cli_cloud_wiring.credentials_result
      ~provider
      ~operation:"uninstalling the durable installation for"
      ~leaves_target_standing:false
    |> Sol_cli_exit.of_msg
  in
  let* () =
    Sol_cli_cloud_wiring.init_result
      ~assets
      run_log
      ~provider
      ~role:Sol_cli_platform_assets.Bootstrap
      backend
    |> Sol_cli_exit.of_msg
  in
  let* addresses =
    Sol_cli_terraform.state_addresses ~chdir ()
    |> Result.map_error Sol_cli_process.error_to_string
    |> Sol_cli_exit.of_msg
  in
  let zone_address = capabilities.installation_zone_address in
  let addresses_the_zone = Sol_cli_installation.address_in_zone ~zone:zone_address in
  let plan =
    Sol_cli_installation_uninstall.plan
      ~prerequisites:(Sol_cli_provider_capabilities.installation_prerequisites provider)
      ~created:(Sol_cli_provider_capabilities.installation_created_prerequisites provider)
      ~zone_in_state:(List.exists addresses_the_zone addresses)
      configuration
  in
  Printf.printf
    "\n\
     Uninstall plan for %s -- the durable installation that outlives every environment:\n\n\
     %!"
    target;
  Sol_cli_installation_uninstall.lines plan
  |> List.iter (fun line -> Printf.printf "  %s\n%!" line);
  let var_files = Option.to_list var_file in
  let destroy_vars =
    Sol_cli_terraform.kv_args
      (Sol_cli_provider_capabilities.installation_vars
         provider
         ~manage_dns_zone:
           (Sol_cli_installation.owns_the_zone configuration.Sol_cli_installation.zone)
         configuration)
    @ vars
  in
  let terraform name run =
    Sol_cli_run_log.run_phase run_log ~name run
    |> Sol_cli_terraform_steps.terraform_outcome
  in
  let installation_observation = Cmd_cloud_tf.installation_observation ~provider in
  let deps : Sol_cli_installation_uninstall_stage.deps =
    { release_state_backend =
        (fun () ->
          terraform "installation-uninstall-release-state-backend" (fun () ->
            Sol_cli_terraform.state_rm
              ~chdir
              ~address:capabilities.installation_state_backend_address
              ()))
    ; unmanage_zone =
        (fun () ->
          terraform "installation-uninstall-unmanage-zone" (fun () ->
            Sol_cli_terraform.state_rm
              ~chdir
              ~address:capabilities.installation_zone_import_address
              ()))
    ; destroy =
        (fun () ->
          terraform "installation-destroy" (fun () ->
            Sol_cli_terraform.destroy ~chdir ~var_files ~vars:destroy_vars ()))
    ; retire_state_backend =
        (fun () ->
          capabilities.installation_retire_state_backend
            ~run:installation_observation
            configuration)
    ; observe =
        (fun () ->
          Sol_cli_provider_capabilities.installation_probes provider configuration
          |> Sol_cli_installation.observe ~run:installation_observation)
    ; warn = (fun line -> Printf.eprintf "%s\n%!" line)
    }
  in
  let outcome =
    Sol_cli_installation_uninstall_stage.execute
      ~deps
      ~plan
      ~state_backend_in_state:
        (List.mem capabilities.installation_state_backend_address addresses)
      ~confirm
      ~dns_confirmation:confirm_dns_zone
  in
  match outcome with
  | Sol_cli_installation_uninstall_stage.Uninstall_refused reason ->
    Printf.eprintf "error: %s\n%!" reason;
    Error (Sol_cli_exit.reported ~code:1 ())
  | Sol_cli_installation_uninstall_stage.Uninstall_succeeded removed ->
    Printf.printf "\nRemoved and independently observed absent:\n%!";
    (match removed with
     | [] -> Printf.printf "  nothing durable\n%!"
     | removed ->
       List.iter
         (fun prerequisite ->
            Printf.printf
              "  %s\n%!"
              (Sol_cli_installation.prerequisite_label prerequisite))
         removed);
    print_retained plan;
    Printf.printf
      "\n\
       Done. The installation's Sol-owned durable resources are gone; nothing else was \
       touched.\n\
       %!";
    Ok ()
  | Sol_cli_installation_uninstall_stage.Uninstall_failed { failure; verification } ->
    Sol_cli_installation_uninstall.verification_lines verification
    |> List.iter (fun line -> Printf.printf "%s\n%!" line);
    print_retained plan;
    Printf.eprintf
      "error: %s\n%!"
      (Sol_cli_installation_uninstall_stage.failure_message failure);
    Error (Sol_cli_exit.reported ~code:1 ())
;;

let confirm_flag =
  Arg.(
    value
    & flag
    & info
        [ "confirm" ]
        ~doc:
          "Perform the removal. Without it the plan is printed and nothing is changed: \
           this command removes the durable installation, which no environment teardown \
           touches.")
;;

let confirm_dns_zone_flag =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "confirm-dns-zone" ]
        ~docv:"DOMAIN"
        ~doc:
          "Confirm the removal of a Sol-created delegated zone by naming its exact \
           domain. Required whenever the plan removes one, because the NS records at \
           your registrar become stale and a recreated zone gets different nameservers.")
;;

let cmd =
  let doc =
    "Remove a Sol installation: its Sol-owned durable resources, and nothing else."
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "The installation is the durable account-level layer that outlives every \
         environment (DEC-057): the Terraform state facility, the delegated DNS zone \
         when Sol owns it, and the provisioning objects the durable root manages. `sol \
         cloud destroy <target>` removes an environment and leaves all of this standing; \
         this command is the only supported way to remove it, and it is never implied by \
         destroying environments."
    ; `P
        "Sol prints what it will remove and what it will keep before changing anything, \
         and refuses without --confirm. Removing a Sol-created delegated zone has a \
         visible external effect — the NS records at your registrar become stale — so it \
         needs its own confirmation naming the exact domain, and a user-supplied or \
         externally delegated zone is never removed."
    ; `P
        "The Terraform state facility is a structural exception: a root cannot destroy \
         the backend that stores its own state, so Sol takes it out of the root's state \
         before destroying the root and retires it explicitly afterwards. Identity \
         objects the durable root does not create (the operator creates those from its \
         policy output) are reported as retained, never deleted."
    ; `P
        "Success is an observation, not an exit code (DEC-044, DEC-040): after the \
         removal Sol re-observes each resource with the installation's own probes and \
         reports which are absent. An unqueryable answer is UNKNOWN and fails closed — \
         Sol never reports a resource removed because a command exited zero."
    ; `P
        "The target is the positional and the environment is a property of it, matching \
         `sol plan` and is established inline by `sol deploy` (DEC-016, DEC-031)."
    ; `S "EXIT STATUS"
    ; `P "0 -- every Sol-owned resource in the plan was observed absent."
    ; `P
        "1 -- nothing was changed (no --confirm, or the DNS confirmation did not name \
         the zone), or a removal did not complete, or absence could not be observed. The \
         reason and the per-resource observation are printed."
    ; `P "No other code is used by this command."
    ]
  in
  Cmd.v
    (Cmd.info "uninstall" ~doc ~man)
    Term.(
      const (fun target var_file vars confirm confirm_dns_zone ->
        Sol_cli_exit.exit_on
          (uninstall ~target ~var_file ~vars ~confirm ~confirm_dns_zone ()))
      $ Cmd_cloud_tf.target_arg
      $ Cmd_cloud_tf.var_file_arg
      $ Cmd_cloud_tf.var_arg
      $ confirm_flag
      $ confirm_dns_zone_flag)
;;
