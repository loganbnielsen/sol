open Cmdliner

let render_opt out label = function
  | None -> ()
  | Some v -> Printf.bprintf out "  %-14s %s\n" label v
;;

let render_index out (index : Sol_cli_config.index) =
  Printf.bprintf out "    index %s" index.index_name;
  match index.partition_key, index.sort_key with
  | None, None -> Printf.bprintf out "\n"
  | partition_key, sort_key ->
    Printf.bprintf
      out
      " (partition_key=%s sort_key=%s)\n"
      (Option.value partition_key ~default:"?")
      (Option.value sort_key ~default:"?")
;;

let render ~project ~target_name (cfg : Sol_cli_config.t) =
  let out = Buffer.create 256 in
  let target = cfg.target in
  let resources = Sol_cli_config.resources cfg in
  let services = Sol_cli_config.services cfg in
  Printf.bprintf out "Project: %s\n" project;
  Printf.bprintf out "Target: %s\n\n" target_name;
  Printf.bprintf out "Target config:\n";
  render_opt out "env" (Some target.env);
  render_opt out "provider" (Some (Sol_cli_provider.to_string target.provider));
  render_opt out "region" (Some target.region);
  render_opt out "registry" target.registry;
  render_opt out "cluster" target.cluster_name;
  render_opt out "domain" target.base_domain;
  render_opt out "cluster issuer" target.cluster_issuer;
  Printf.bprintf out "\nResources:\n";
  if resources = [] then Printf.bprintf out "  (none)\n";
  resources
  |> List.iter (fun (r : Sol_cli_config.resource) ->
    let type_suffix =
      match r.typ with
      | None -> ""
      | Some t -> " (" ^ t ^ ")"
    in
    Printf.bprintf out "  - %s%s\n" r.name type_suffix;
    List.iter (render_index out) r.indexes);
  Printf.bprintf out "\nServices:\n";
  if services = [] then Printf.bprintf out "  (none)\n";
  services
  |> List.iter (fun s ->
    let type_suffix =
      match s.typ with
      | None -> ""
      | Some t -> " (" ^ t ^ ")"
    in
    Printf.bprintf out "  - %s%s\n" s.Sol_cli_config.name type_suffix;
    render_opt out "path" s.path;
    if s.uses <> []
    then
      Printf.bprintf
        out
        "    uses: %s\n"
        (String.concat ", " (List.map Sol_cli_config.format_use_ref s.uses));
    match s.scale_min, s.scale_max with
    | None, None -> ()
    | min, max ->
      Printf.bprintf
        out
        "    scale: %s..%s\n"
        (Option.fold ~none:"?" ~some:string_of_int min)
        (Option.fold ~none:"?" ~some:string_of_int max));
  Buffer.contents out
;;

let run target_name =
  let open Result.Syntax in
  let* cfg =
    Sol_cli_config.load_for_target ~target:target_name
    |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
  in
  let project = Option.value cfg.project ~default:(Filename.basename (Sys.getcwd ())) in
  print_string (render ~project ~target_name cfg);
  Ok ()
;;

let target_arg =
  Arg.(
    required
    & pos 0 (some Sol_cli_args.text) None
    & info [] ~docv:"TARGET" ~doc:"Deployment target path: <env>/<provider>/<region>.")
;;

let cmd =
  Cmd.v
    (Cmd.info "plan" ~doc:"Print the merged Sol app/resource/service plan for a target.")
    Term.(const Sol_cli_exit.exit_on $ (const run $ target_arg))
;;
