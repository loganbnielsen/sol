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
        message);
    Printf.eprintf
      "warning: destruction reached absence with %d degraded preparation(s)\n%!"
      (List.length degradations)
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
  let* () =
    guard_previous_operation
      ~constructive:false
      ~accept_unresolved:false
      ~chdir:
        (workdir
           provider
           Sol_cli_platform_assets.Platform
           ~backend_config:(Sol_cli_cloud_lifecycle.platform_backend cloud_target))
      ~backend_config:(Sol_cli_cloud_lifecycle.platform_backend cloud_target)
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
       Printf.printf
         (if degradations = []
          then "\nDone.\n%!"
          else "\nDone, with a degraded preparation.\n%!")
     | Sol_cli_cloud_destroy.Destroy_blocked { guarantee } ->
       Printf.eprintf
         "error: destruction is blocked -- proceeding would violate a destruction-time \
          guarantee this target declared: %s\n\
          %!"
         guarantee
     | Sol_cli_cloud_destroy.Destroy_failed
         { failure; degradations; cleanup; verification } ->
       report_cleanup_evidence cleanup;
       report_degradations degradations;
       verification |> Option.iter report_verification;
       Printf.eprintf "error: %s\n%!" (Sol_cli_cloud_destroy.failure_message failure));
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
