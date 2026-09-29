open Cmdliner
open Result.Syntax

let print_outputs infra_dir =
  match
    Sol_cli_terraform.output_json ~chdir:infra_dir ()
    |> Result.map (fun r -> r.Sol_cli_process.stdout)
  with
  | Error e ->
    Printf.printf
      "  (could not retrieve terraform outputs: %s)\n%!"
      (Sol_cli_process.error_to_string e)
  | Ok json ->
    (match Sol_cli_terraform_outputs.displayable json with
     | Ok outputs ->
       outputs
       |> List.iter (fun output -> print_endline (Sol_cli_terraform_outputs.line output))
     | Error reason -> Printf.printf "  (could not read terraform outputs: %s)\n%!" reason)
;;

let refuse message = Error (Sol_cli_exit.error message)

let provider_of_target_path target =
  match String.split_on_char '/' target with
  | [ _env; provider; _region ] ->
    (match Sol_cli_provider.of_string provider with
     | Some provider -> Ok provider
     | None ->
       refuse (Printf.sprintf "unsupported provider %S in target %S." provider target))
  | _ -> refuse "target must look like <env>/<provider>/<region>."
;;

let check_terraform () =
  if Sol_cli_terraform.which_check ()
  then Ok ()
  else
    refuse
      (Printf.sprintf
         "%S not found in PATH.\n  Install: %s"
         "terraform"
         "https://developer.hashicorp.com/terraform/install")
;;

let resolve_assets () =
  Sol_cli_platform_assets.resolve ()
  |> Sol_cli_exit.of_error Sol_cli_platform_assets.error_to_string
;;

let asset_root ~assets provider role =
  let dir = Sol_cli_platform_assets.cloud_root assets provider role in
  if Sys.file_exists dir then Ok dir else refuse ("Terraform module not found: " ^ dir)
;;

type action =
  | Plan
  | Apply

let action_of_flags plan apply =
  match plan, apply with
  | true, false -> `Ok Plan
  | false, true -> `Ok Apply
  | false, false -> `Ok Plan
  | true, true -> `Error (false, "--plan and --apply are mutually exclusive")
;;

let resolve_var_file ~flag ~target =
  let cwd = Sys.getcwd () in
  let workspace_root = Option.value (Sol_cli_workspace.find_root ~dir:cwd) ~default:cwd in
  Sol_cli_terraform_vars.var_file ~cwd ~workspace_root ~flag ~target
;;

let target_vars ~strict target =
  Sol_cli_terraform_vars.of_target
    ~strict
    ~workspace:(Sol_cli_workspace.current_name ())
    target
  |> Result.map (fun (vars, target_cfg) -> Sol_cli_terraform.kv_args vars, target_cfg)
  |> Sol_cli_exit.of_msg
;;

let guard_previous_operation ~constructive ~accept_unresolved ~chdir ~backend_config =
  Sol_cli_state_guard.check ~constructive ~accept_unresolved ~chdir ~backend_config
  |> Sol_cli_exit.of_msg
;;

let require_credentials ~provider ~operation ~leaves_target_standing =
  Sol_cli_provider_registry.credentials provider ~operation ~leaves_target_standing
  |> Sol_cli_exit.of_msg
;;

let of_apply_failure r =
  Result.map_error
    (function
      | Sol_cli_cloud_apply.Terraform_failed message ->
        Sol_cli_exit.failure ("\n" ^ message)
      | Sol_cli_cloud_apply.Refused message -> Sol_cli_exit.error message)
    r
;;

let refuse_sensitive_vars ~infra_dir ~vars =
  match
    Result.bind (Sol_cli_sensitive_vars.declared ~root:infra_dir) (fun sensitive ->
      Sol_cli_sensitive_vars.refuse_on_command_line ~sensitive ~vars)
  with
  | Ok () -> Ok ()
  | Error msg -> Error (Sol_cli_exit.failure ("\nerror: " ^ msg))
;;

let report_cleanup_evidence = function
  | Sol_cli_cloud_destroy.Cleanup_failed message ->
    Printf.eprintf
      "warning: removing the bootstrap access failed (%s); the elevated access may still \
       be applied\n\
       %!"
      message
  | Sol_cli_cloud_destroy.Cleanup_not_needed | Sol_cli_cloud_destroy.Cleanup_succeeded ->
    ()
;;

let report_verification observation =
  Printf.printf "%s%!" (Sol_cli_destroy_verification.report observation)
;;

let workdir provider role ~backend_config =
  Sol_cli_terraform_workdir.chdir ~provider ~role ~backend_config
;;

let cloud_init
      ?(confirm_ecr_removal = false)
      ?(accept_unresolved = false)
      ~target
      ~var_file
      ~vars
      ~action
      ()
  =
  let* () = check_terraform () in
  let* provider = provider_of_target_path target in
  let pname = Sol_cli_provider.to_string provider in
  let* assets = resolve_assets () in
  let* cluster_assets = asset_root ~assets provider Sol_cli_platform_assets.Cluster in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-apply" () in
  let* config_vars, target_cfg = target_vars ~strict:(action = Apply) target in
  let var_file = resolve_var_file ~flag:var_file ~target:target_cfg.terraform_var_file in
  let vars =
    Sol_cli_config.vars_with_profile_precedence
      ~has_profile:(Option.is_some target_cfg.profile)
      ~cli_vars:vars
      ~config_vars
  in
  let* cloud_target =
    Sol_cli_cloud_lifecycle.cloud_target target_cfg |> Sol_cli_exit.of_msg
  in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
  let infra_dir =
    workdir provider Sol_cli_platform_assets.Cluster ~backend_config:cloud_backend
  in
  let platform_dir =
    workdir provider Sol_cli_platform_assets.Platform ~backend_config:platform_backend
  in
  let var_files = Option.to_list var_file in
  let inputs : Sol_cli_cloud_wiring.terraform_inputs = { var_files; vars } in
  let* () = refuse_sensitive_vars ~infra_dir:cluster_assets ~vars in
  Printf.printf "\nInitializing cloud infrastructure (%s)...\n%!" pname;
  let* () =
    match action with
    | Plan -> Ok ()
    | Apply ->
      require_credentials ~provider ~operation:"applying" ~leaves_target_standing:false
  in
  let* () =
    guard_previous_operation
      ~constructive:(action = Apply)
      ~accept_unresolved
      ~chdir:infra_dir
      ~backend_config:cloud_backend
  in
  let* () =
    if action = Apply
    then
      guard_previous_operation
        ~constructive:true
        ~accept_unresolved
        ~chdir:platform_dir
        ~backend_config:platform_backend
    else Ok ()
  in
  let* () =
    Sol_cli_cloud_wiring.init
      ~assets
      run_log
      ~provider
      ~role:Sol_cli_platform_assets.Cluster
      cloud_backend
    |> of_apply_failure
  in
  match action with
  | Plan ->
    let* () =
      Sol_cli_cloud_wiring.plan ~assets ~run_log ~cloud_target ~inputs |> of_apply_failure
    in
    Printf.printf "\nDone. Re-run with 'sol cloud apply' to change cloud resources.\n%!";
    Ok ()
  | Apply ->
    let outcome =
      Sol_cli_cloud_apply.execute
        ~deps:
          (Sol_cli_cloud_wiring.apply_deps
             ~assets
             ~confirm_ecr_removal
             ~run_log
             ~cloud_target
             ~inputs)
    in
    (match outcome with
     | Sol_cli_cloud_apply.Applied ->
       Printf.printf "\nProvisioned endpoints:\n%!";
       print_outputs infra_dir;
       Printf.printf "\nDone.\n%!";
       Ok ()
     | Sol_cli_cloud_apply.Apply_failed { failure; cleanup } ->
       report_cleanup_evidence cleanup;
       Error failure |> of_apply_failure)
;;

let report_degradations = function
  | [] -> ()
  | degradations ->
    degradations
    |> List.iter (fun message ->
      Printf.eprintf
        "warning: a preparation degraded and destruction continued -- %s\n%!"
        message)
;;

let cloud_destroy ~target ~var_file ~vars ~action () =
  let* () = check_terraform () in
  let* provider = provider_of_target_path target in
  let pname = Sol_cli_provider.to_string provider in
  let* assets = resolve_assets () in
  let* cluster_assets = asset_root ~assets provider Sol_cli_platform_assets.Cluster in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-destroy" () in
  let* config_vars, target_cfg = target_vars ~strict:(action = Apply) target in
  let var_file = resolve_var_file ~flag:var_file ~target:target_cfg.terraform_var_file in
  let vars = config_vars @ vars in
  let* () = refuse_sensitive_vars ~infra_dir:cluster_assets ~vars in
  let* retention =
    match target_cfg.destroy_retention with
    | None -> Ok Sol_cli_cloud_lifecycle.default_destroy_retention
    | Some raw ->
      Sol_cli_cloud_lifecycle.destroy_retention_of_string raw |> Sol_cli_exit.of_msg
  in
  let* cloud_target =
    Sol_cli_cloud_lifecycle.cloud_target target_cfg |> Sol_cli_exit.of_msg
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let infra_dir =
    workdir provider Sol_cli_platform_assets.Cluster ~backend_config:cloud_backend
  in
  let* () =
    guard_previous_operation
      ~constructive:false
      ~accept_unresolved:false
      ~chdir:infra_dir
      ~backend_config:cloud_backend
  in
  let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
  let platform_dir =
    workdir provider Sol_cli_platform_assets.Platform ~backend_config:platform_backend
  in
  let* () =
    guard_previous_operation
      ~constructive:false
      ~accept_unresolved:false
      ~chdir:platform_dir
      ~backend_config:platform_backend
  in
  let var_files = Option.to_list var_file in
  let inputs : Sol_cli_cloud_wiring.terraform_inputs = { var_files; vars } in
  let destruction =
    Sol_cli_cloud_wiring.destruction
      ~run_log
      ~provider
      ~target_cfg
      ~infra_dir
      ~var_files
      ~vars
  in
  Printf.printf "\nDestroying cloud infrastructure (%s)...\n%!" pname;
  match action with
  | Plan ->
    let* () =
      Sol_cli_cloud_wiring.destroy_preview ~assets ~run_log ~cloud_target ~inputs
      |> Sol_cli_exit.of_msg
    in
    Printf.printf "\nDone. Re-run with --apply to destroy cloud resources.\n%!";
    Ok ()
  | Apply ->
    let deps =
      Sol_cli_cloud_wiring.destroy_deps
        ~assets
        ~run_log
        ~cloud_target
        ~inputs
        ~retention
        ~destruction
    in
    let outcome = Sol_cli_cloud_destroy.execute ~deps in
    (match outcome with
     | Sol_cli_cloud_destroy.Destroy_succeeded { degradations; cleanup; verification; _ }
       ->
       report_cleanup_evidence cleanup;
       report_degradations degradations;
       report_verification verification;
       Printf.printf "\n%s\n%!" (Sol_cli_cloud_destroy.completion_message outcome)
     | Sol_cli_cloud_destroy.Destroy_blocked { guarantee } ->
       Printf.eprintf
         "error: destruction is blocked -- proceeding would violate a destruction-time \
          guarantee this target declared: %s\n\
          %!"
         guarantee
     | Sol_cli_cloud_destroy.Destroy_failed
         { failure = _; degradations; cleanup; verification } ->
       report_cleanup_evidence cleanup;
       report_degradations degradations;
       verification |> Option.iter report_verification;
       Printf.eprintf "error: %s\n%!" (Sol_cli_cloud_destroy.completion_message outcome));
    (match Sol_cli_cloud_destroy.exit_code outcome with
     | 0 -> Ok ()
     | code -> Error (Sol_cli_exit.reported ~code ()))
;;

let var_file_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "var-file" ]
        ~docv:"PATH"
        ~doc:"Path to a Terraform .tfvars file. Passed as -var-file to terraform.")
;;

let target_arg =
  Arg.(
    required
    & pos 0 (some Sol_cli_args.text) None
    & info [] ~docv:"TARGET" ~doc:"Deployment target path: <env>/<provider>/<region>.")
;;

let var_arg =
  Arg.(
    value
    & opt_all Sol_cli_args.text []
    & info
        [ "var" ]
        ~docv:"KEY=VALUE"
        ~doc:"Terraform variable. Can be passed multiple times.")
;;

let recover_one
      ~infra_dir
      ~var_files
      ~vars
      (candidate : Sol_cli_ownership_recovery.candidate)
  =
  Printf.printf
    "  importing %s as %s (identity %s)...\n%!"
    candidate.found
    candidate.address
    candidate.import_identity;
  match
    Sol_cli_terraform.import_
      ~chdir:infra_dir
      ~var_files
      ~vars
      ~address:candidate.address
      ~import_identity:candidate.import_identity
      ()
  with
  | Error error ->
    Error
      (Printf.sprintf
         "%s could not be imported into %s: %s"
         candidate.found
         candidate.address
         (Sol_cli_process.error_to_string error))
  | Ok _ ->
    (match Sol_cli_terraform.show_json ~chdir:infra_dir () with
     | Error error ->
       Error
         (Printf.sprintf
            "imported %s, but the state could not be re-read: %s"
            candidate.address
            (Sol_cli_process.error_to_string error))
     | Ok result ->
       let after = Sol_cli_cloud_destroy.inventory_of_show_json result.stdout in
       let owned =
         Sol_cli_cloud_destroy.resources after
         |> List.find_opt (fun (resource : Sol_cli_cloud_destroy.resource) ->
           resource.address = candidate.address)
       in
       (match owned with
        | None ->
          Error
            (Printf.sprintf
               "the import of %s reported success, but the state does not represent it \
                afterwards"
               candidate.address)
        | Some resource ->
          let observed = Option.value resource.identifier ~default:"" in
          let agrees =
            Sol_cli_string.is_blank observed
            || Sol_cli_string.contains ~needle:observed candidate.import_identity
            || Sol_cli_string.contains ~needle:candidate.import_identity observed
          in
          if agrees
          then (
            Printf.printf
              "    %s now owns %s (provider id %s)\n%!"
              candidate.address
              candidate.found
              (if Sol_cli_string.is_blank observed then "(none recorded)" else observed);
            Ok ())
          else
            Error
              (Printf.sprintf
                 "the state now holds %s with provider id %s, which is not the identity \
                  %s that was imported, so the adoption is ambiguous"
                 candidate.address
                 observed
                 candidate.import_identity)))
;;

let cloud_recover ~target ~var_file ~vars ~action () =
  let* () = check_terraform () in
  let* provider = provider_of_target_path target in
  let pname = Sol_cli_provider.to_string provider in
  let* assets = resolve_assets () in
  let* cluster_assets = asset_root ~assets provider Sol_cli_platform_assets.Cluster in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-recover" () in
  let* config_vars, target_cfg = target_vars ~strict:true target in
  let var_file = resolve_var_file ~flag:var_file ~target:target_cfg.terraform_var_file in
  let vars = config_vars @ vars in
  let* () = refuse_sensitive_vars ~infra_dir:cluster_assets ~vars in
  let* () =
    Sol_cli_cloud_wiring.credentials_result
      ~provider
      ~operation:"recovering ownership for"
      ~leaves_target_standing:true
    |> Sol_cli_exit.of_msg
  in
  let* cloud_target =
    Sol_cli_cloud_lifecycle.cloud_target target_cfg |> Sol_cli_exit.of_msg
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let infra_dir =
    workdir provider Sol_cli_platform_assets.Cluster ~backend_config:cloud_backend
  in
  let* () =
    guard_previous_operation
      ~constructive:false
      ~accept_unresolved:false
      ~chdir:infra_dir
      ~backend_config:cloud_backend
  in
  let* () =
    Sol_cli_cloud_wiring.init_result
      ~assets
      run_log
      ~provider
      ~role:Sol_cli_platform_assets.Cluster
      cloud_backend
    |> Sol_cli_exit.of_msg
  in
  let* cluster_name =
    match target_cfg.cluster_name with
    | Some name when not (Sol_cli_string.is_blank name) -> Ok name
    | _ ->
      Error
        (Sol_cli_exit.error
           "recovery needs the target's cluster_name: both the provider inventory and \
            the identity registry address resources by it, so without it nothing can be \
            attributed or mapped")
  in
  let state =
    match Sol_cli_terraform.show_json ~chdir:infra_dir () with
    | Ok result -> Sol_cli_cloud_destroy.inventory_of_show_json result.stdout
    | Error (Sol_cli_process.Non_zero result) ->
      Sol_cli_cloud_destroy.State_unreadable
        (Printf.sprintf "terraform show exited %d" result.exit_code)
    | Error error ->
      Sol_cli_cloud_destroy.State_unreadable
        ("terraform show could not be run: " ^ Sol_cli_process.error_to_string error)
  in
  let state_addresses = Sol_cli_cloud_destroy.addresses state in
  let observations =
    Sol_cli_provider_registry.observations provider target_cfg ~cluster_name
  in
  let dispositions =
    Sol_cli_ownership_recovery.dispositions
      ~entries:(Sol_cli_provider_registry.resource_identity provider ~cluster_name)
      ~class_rules:Sol_cli_resource_identity.class_rules
      ~descendants:(Sol_cli_resource_identity.descendants ~cluster_name)
      ~state_addresses
      observations
  in
  Printf.printf
    "\nRecovering Terraform ownership for %s (%s, cluster %s)...\n%!"
    target
    pname
    cluster_name;
  Printf.printf "%s%!" (Sol_cli_absence.report observations);
  Printf.printf "%s%!" (Sol_cli_ownership_recovery.report dispositions);
  Printf.printf "  %s\n%!" (Sol_cli_ownership_recovery.summary dispositions);
  let candidates = List.filter_map Sol_cli_ownership_recovery.candidate dispositions in
  match action with
  | Plan ->
    (match candidates with
     | [] ->
       Printf.printf
         "\n\
          Done. Nothing here restores Terraform ownership; --apply would re-check the \
          same question.\n\
          %!";
       Ok ()
     | candidates ->
       Printf.printf
         "\n\
          %d resource(s) can be brought back under Terraform ownership. Re-run with \
          --apply to import them.\n\
          %!"
         (List.length candidates);
       Ok ())
  | Apply ->
    let var_files = Option.to_list var_file in
    let recovered =
      List.fold_left
        (fun acc candidate ->
           match acc with
           | Error _ as error -> error
           | Ok count ->
             (match recover_one ~infra_dir ~var_files ~vars candidate with
              | Error _ as error -> error
              | Ok () -> Ok (count + 1)))
        (Ok 0)
        candidates
    in
    (match recovered with
     | Error message ->
       Printf.eprintf "error: %s\n%!" message;
       Error (Sol_cli_exit.reported ~code:1 ())
     | Ok count ->
       Printf.printf "\n%d resource(s) brought back under Terraform ownership.\n%!" count;
       let outstanding = Sol_cli_ownership_recovery.outstanding dispositions in
       if outstanding = []
       then Ok ()
       else (
         Printf.eprintf
           "error: %d resource(s) attributable to this target remain outside Terraform \
            ownership, and Sol will not guess at them:\n\
            %!"
           (List.length outstanding);
         Printf.eprintf "%s%!" (Sol_cli_ownership_recovery.report outstanding);
         Error (Sol_cli_exit.reported ~code:1 ())))
;;

let plan_flag =
  Arg.(
    value
    & flag
    & info
        [ "plan" ]
        ~doc:"Run terraform plan only. No infrastructure is changed. This is the default.")
;;

let apply_flag =
  Arg.(
    value
    & flag
    & info
        [ "apply" ]
        ~doc:"Run terraform apply/destroy and change billable cloud resources.")
;;

let action_term = Term.(ret (const action_of_flags $ plan_flag $ apply_flag))

let confirm_ecr_removal_flag =
  Arg.(
    value
    & flag
    & info
        [ Sol_cli_cloud_wiring.confirm_guarded_removal_flag ]
        ~doc:
          "Allow an apply whose plan deletes a resource the provider declares guarded \
           (AWS: ECR repositories, and every image in them). Without it such an apply is \
           refused before anything changes.")
;;

let accept_unresolved_flag =
  Arg.(
    value
    & flag
    & info
        [ "accept-unresolved" ]
        ~doc:
          "Proceed although the previous Terraform operation against this state ended \
           unresolved (Terraform was killed before finishing its own shutdown, or left \
           errored.tfstate). Use it only after reconciling: inspecting the provider and \
           the state, and importing, removing or pushing what diverged. Without it such \
           an apply is refused before anything changes.")
;;

let plan_cmd =
  Cmd.v
    (Cmd.info "plan" ~doc:"Preview cloud infrastructure changes for a target.")
    Term.(
      const (fun target var_file vars ->
        Sol_cli_exit.exit_on (cloud_init ~target ~var_file ~vars ~action:Plan ()))
      $ target_arg
      $ var_file_arg
      $ var_arg)
;;

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply cloud infrastructure changes for a target.")
    Term.(
      const (fun target var_file vars confirm_ecr_removal accept_unresolved ->
        Sol_cli_exit.exit_on
          (cloud_init
             ~confirm_ecr_removal
             ~accept_unresolved
             ~target
             ~var_file
             ~vars
             ~action:Apply
             ()))
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ confirm_ecr_removal_flag
      $ accept_unresolved_flag)
;;

let destroy_cmd =
  let doc =
    "Destroy cloud infrastructure via Terraform. Requires the same target/provider used \
     with apply."
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Destruction proceeds even when a best-effort preparation -- lowering a deletion \
         guard -- fails or its plan is refused: the failure is reported, the unsafe \
         apply is never executed, and what Terraform represents is still destroyed. Only \
         a failure that stands for a destruction-time guarantee the target itself \
         declared (such as `destroy_retention: final-snapshot`, which could not be \
         prepared) blocks destruction and leaves the target standing."
    ; `S "EXIT STATUS"
    ; `P
        "0 -- destruction reached absence and it was verified. A best-effort preparation \
         that failed or was refused does not change this (REFAC-094): each one is \
         reported on stderr as a warning."
    ; `P
        "1 -- destruction did not reach its postcondition: it failed, it was blocked by \
         a declared guarantee, absence could not be verified, or the elevated bootstrap \
         access could not be removed. The reason is named on stderr."
    ; `P "No other code is used by this command."
    ]
  in
  Cmd.v
    (Cmd.info "destroy" ~doc ~man)
    Term.(
      const (fun target var_file vars action ->
        Sol_cli_exit.exit_on (cloud_destroy ~target ~var_file ~vars ~action ()))
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ action_term)
;;

let recover_cmd =
  let doc =
    "Restore Terraform ownership of provider resources this target caused to exist but \
     the disposable root's state never adopted."
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Terraform is the mutation authority and the provider is the reality authority. \
         When an apply fails after the provider has created something, the state may not \
         represent it, and a state-driven destroy then cannot remove it. This command \
         observes the provider independently, maps each resource it finds to a Terraform \
         address through the identity registry, and imports it so the ordinary lifecycle \
         can act on it."
    ; `P
        "It refuses to guess. A resource whose class has no registry entry, whose class \
         the registry marks as not recoverable (a composite provider identity, a \
         module's internals, a name that depends on the workspace layout), or whose name \
         matches more than one address, is reported and left alone. Resources that are \
         external or durable by contract, and resources a controller created on behalf \
         of something Terraform owns, are reported as their owner's business rather than \
         imported."
    ; `P
        "Import evaluates the whole configuration, so the target's Terraform variables \
         must be resolvable exactly as an apply needs them, including any the operator \
         supplies through the environment (TF_VAR_*). Sol never takes a secret on the \
         command line."
    ; `S "EXIT STATUS"
    ; `P
        "0 -- nothing outstanding: every resource the provider holds for this target is \
         either owned already, not this target's to recover, or imported by this run."
    ; `P
        "1 -- something remains that Sol cannot safely recover, or an import failed. The \
         reason is named on stderr, and nothing is guessed."
    ]
  in
  Cmd.v
    (Cmd.info "recover" ~doc ~man)
    Term.(
      const (fun target var_file vars action ->
        Sol_cli_exit.exit_on (cloud_recover ~target ~var_file ~vars ~action ()))
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ action_term)
;;
