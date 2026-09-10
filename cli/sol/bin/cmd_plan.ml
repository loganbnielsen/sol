open Cmdliner

let print_opt label = function
  | None -> ()
  | Some v -> Printf.printf "  %-14s %s\n" label v
;;

let print_index (index : Sol_cli_config.index) =
  Printf.printf "    index %s" index.index_name;
  match index.partition_key, index.sort_key with
  | None, None -> Printf.printf "\n"
  | partition_key, sort_key ->
    Printf.printf
      " (partition_key=%s sort_key=%s)\n"
      (Option.value partition_key ~default:"?")
      (Option.value sort_key ~default:"?")
;;

let run target_name =
  match Sol_cli_config.load_for_target ~target:target_name with
  | Error e ->
    Printf.eprintf "error: %s\n" (Sol_cli_config.error_to_string e);
    exit 1
  | Ok cfg ->
    let project = Option.value cfg.project ~default:(Filename.basename (Sys.getcwd ())) in
    (match Sol_cli_config.target cfg with
     | None ->
       Printf.eprintf "error: target %S not found\n" target_name;
       exit 1
     | Some target ->
       let resources = Sol_cli_config.resources cfg in
       let services = Sol_cli_config.services cfg in
       Printf.printf "Project: %s\n" project;
       Printf.printf "Target: %s\n\n" target_name;
       Printf.printf "Target config:\n";
       print_opt "env" (Some target.env);
       print_opt "provider" (Some (Sol_cli_provider.to_string target.provider));
       print_opt "region" (Some target.region);
       print_opt "registry" target.registry;
       print_opt "cluster" target.cluster_name;
       print_opt "domain" target.base_domain;
       Printf.printf "\nResources:\n";
       if resources = [] then Printf.printf "  (none)\n";
       List.iter
         (fun (r : Sol_cli_config.resource) ->
            Printf.printf
              "  - %s%s\n"
              r.Sol_cli_config.name
              (match r.typ with
               | None -> ""
               | Some t -> " (" ^ t ^ ")");
            List.iter print_index r.indexes)
         resources;
       Printf.printf "\nServices:\n";
       if services = [] then Printf.printf "  (none)\n";
       List.iter
         (fun (s : Sol_cli_config.service) ->
            Printf.printf
              "  - %s%s\n"
              s.Sol_cli_config.name
              (match s.typ with
               | None -> ""
               | Some t -> " (" ^ t ^ ")");
            print_opt "path" s.path;
            if s.uses <> []
            then
              Printf.printf
                "    uses: %s\n"
                (String.concat ", " (List.map Sol_cli_config.format_use_ref s.uses));
            match s.scale_min, s.scale_max with
            | None, None -> ()
            | min, max ->
              Printf.printf
                "    scale: %s..%s\n"
                (Option.fold ~none:"?" ~some:string_of_int min)
                (Option.fold ~none:"?" ~some:string_of_int max))
         services)
;;

let target_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"TARGET" ~doc:"Deployment target path: <env>/<provider>/<region>.")
;;

let cmd =
  Cmd.v
    (Cmd.info "plan" ~doc:"Print the merged Sol app/resource/service plan for a target.")
    Term.(const run $ target_arg)
;;
