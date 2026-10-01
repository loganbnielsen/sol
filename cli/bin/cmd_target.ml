let available_target_paths =
  lazy
    (match Sol_cli_workspace_model.load_cwd () with
     | Ok facts -> facts.Sol_cli_workspace_model.targets
     | Error _ -> [])
;;

let available_targets () =
  match Lazy.force available_target_paths with
  | [] -> "no targets found: declare them in sol/environments.yml"
  | paths -> "available targets:\n  " ^ String.concat "\n  " paths
;;

let not_shown message = Sol_cli_exit.failure (message ^ "\n\n" ^ available_targets ())

let first_line text =
  match String.split_on_char '\n' (String.trim text) with
  | line :: _ -> String.trim line
  | [] -> ""
;;

let kubernetes_status ~check (target : Sol_cli_config.target) =
  match Sol_cli_config.destination_of_target target with
  | Error _ -> Sol_cli_target_report.Not_configured
  | Ok destination ->
    let context = destination.context in
    if not check
    then Sol_cli_target_report.Configured context
    else (
      let args = Sol_cli_kube_destination.kubectl_args destination @ [ "cluster-info" ] in
      match
        Sol_cli_kubectl.probe_result
          ~ctx:(Sol_cli_kube_destination.context_of_destination destination)
          ~args
      with
      | Ok Sol_cli_kubectl.Succeeded -> Sol_cli_target_report.Reachable context
      | Ok (Sol_cli_kubectl.Failed failure) ->
        Sol_cli_target_report.Unreachable
          (context, first_line (Sol_cli_process.failure_message failure))
      | Error message -> Sol_cli_target_report.Unreachable (context, message))
;;

let platform_status ~check (target : Sol_cli_config.target) =
  if not check
  then None
  else (
    match Sol_cli_config.destination_of_target target with
    | Error _ -> Some "Unmet — no explicit Kubernetes destination"
    | Ok destination ->
      let prefix = Sol_cli_kube_destination.kubectl_args destination in
      let env = Sol_cli_kube_destination.environment destination in
      let run args =
        match
          Sol_cli_process.run (Sol_cli_process.cmd ~env (("kubectl" :: prefix) @ args))
        with
        | Ok result -> Some result.stdout
        | _ -> None
      in
      Some
        (Sol_cli_cloud_lifecycle.readiness ~provider:target.provider ~run
         |> Sol_cli_cloud_lifecycle.readiness_summary))
;;

let cloud_status (target : Sol_cli_config.target) =
  match Sol_cli_provider_capabilities.observe_installation target with
  | Ok (_, verdicts) -> Sol_cli_installation.health_summary verdicts
  | Error message -> "Unknown — the installation could not be resolved: " ^ message
;;

let drift_status (target : Sol_cli_config.target) =
  let drift =
    match Sol_cli_platform_assets.resolve () with
    | Error error ->
      Sol_cli_environment_stage.Unknown
        ("the platform's Terraform assets are not available: "
         ^ Sol_cli_platform_assets.error_to_string error)
    | Ok assets ->
      Sol_cli_environment_stage.drift
        ~assets
        ~target:target.name
        ~var_file:None
        ~vars:[]
        ()
  in
  Sol_cli_environment_stage.drift_to_string drift
;;

open Result.Syntax

let declared_target target =
  match Sol_cli_config.load_for_target ~target with
  | Error e -> Error (not_shown (Sol_cli_config.error_to_string e))
  | Ok { target = target_config; _ }
    when not (Sol_cli_config.target_declared target_config) ->
    Error
      (not_shown
         (Printf.sprintf
            "target %s is not declared (expected in %s)"
            target
            (Sol_cli_config.target_source target_config)))
  | Ok config -> Ok config.target
;;

let show target verbose json check =
  let* target =
    match target with
    | Some target -> Ok target
    | None -> Error (not_shown "sol target show needs a target — which one?")
  in
  let* target_config = declared_target target in
  let status = kubernetes_status ~check target_config in
  let platform = platform_status ~check target_config in
  let cloud = if check then Some (cloud_status target_config) else None in
  let drift = if check then Some (drift_status target_config) else None in
  if json
  then
    print_endline
      (Yojson.Safe.to_string
         (Sol_cli_target_report.to_json
            ?platform
            ?cloud
            ?drift
            ~verbose
            target_config
            status))
  else
    Sol_cli_target_report.rows ?platform ?cloud ?drift ~verbose target_config status
    |> List.iter (fun (label, value) -> Printf.printf "%-14s %s\n" label value);
  Ok ()
;;

open Cmdliner

let target_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "target" ]
        ~docv:"ENV/PROVIDER/REGION"
        ~doc:
          "The target to show, as a path (e.g. `prod/aws/us-east-1`). Required: there is \
           no current target, and no default (DEC-016).")
;;

let verbose_arg =
  Arg.(
    value
    & flag
    & info
        [ "verbose"; "v" ]
        ~doc:
          "Also show where the target sits and the raw kube-context Sol will use. The \
           context is hidden by default because it is a mechanism, not the target's \
           identity (DEC-020).")
;;

let json_arg = Arg.(value & flag & info [ "json" ] ~doc:"Print the same fields as JSON.")

let check_arg =
  Arg.(
    value
    & flag
    & info
        [ "check" ]
        ~doc:
          "Report live state as well as identity: probe whether the cluster is \
           reachable, observe whether the provider's installation is established, and \
           read whether Terraform's recorded state has drifted from observed reality. \
           Off by default: the summary is also what you read while diagnosing an \
           unreachable cluster, so it must not block before printing. `last operation` \
           is reported either way: it needs no read because Sol keeps no target-scoped \
           record for it.")
;;

let show_cmd =
  let doc = "Show a deployment target" in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Prints a target as a target — provider, region, cluster, registry, base domain \
         — and says whether Sol can reach its cluster. Nothing is inferred: an unknown \
         or missing target fails closed and lists what exists."
    ; `P
        "Every live field names its authority rather than keeping state of its own. \
         `cloud` is the provider's own answer for the installation Sol manages — the \
         same observation `sol cloud bootstrap` reports, never a Sol-side record. \
         `drift` is a read-only, refresh-only Terraform plan, so it compares the \
         recorded state with observed reality without changing either. `last operation` \
         has no target-scoped authority to read, and ADR 0003 forbids adding one, so it \
         is reported as unavailable rather than as `none`."
    ]
  in
  Cmd.v
    (Cmd.info "show" ~doc ~man)
    Term.(
      const Sol_cli_exit.exit_on
      $ (const show $ target_arg $ verbose_arg $ json_arg $ check_arg))
;;

let cmd = Cmd.group (Cmd.info "target" ~doc:"Inspect deployment targets") [ show_cmd ]
