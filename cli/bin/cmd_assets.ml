open Cmdliner

(* FEAT-101 / DEC-049: say where this sol's own assets come from, and prove each
   one its commands read is there and usable -- by running the same code those
   commands run, not by listing paths. Needs no cluster, cloud account, registry
   or Terraform, so an installed release can be checked anywhere. *)

module A = Sol_cli_platform_assets

let form_to_string assets =
  match A.form assets with
  | A.Checkout -> "source checkout"
  | A.Installed { version } -> "installed release " ^ version
;;

let fail fmt =
  Printf.ksprintf
    (fun msg ->
       Printf.eprintf "error: %s\n%!" msg;
       exit 1)
    fmt
;;

let has_terraform dir =
  Sys.file_exists dir
  && Sys.is_directory dir
  && Array.exists (fun f -> Filename.check_suffix f ".tf") (Sys.readdir dir)
;;

let components assets =
  match Yojson.Safe.from_file (A.components_json assets) with
  | `Assoc fields -> List.map fst fields
  | _ -> fail "%s is not a JSON object" (A.components_json assets)
  | exception Yojson.Json_error msg -> fail "%s: %s" (A.components_json assets) msg
  | exception Sys_error msg -> fail "%s" msg
;;

let run () =
  let assets = A.resolve_or_exit () in
  Printf.printf
    "sol %s\nassets: %s\n  root: %s\n\n%!"
    (Option.value Sol_cli_build_info.release_version ~default:Version.v)
    (form_to_string assets)
    (A.dir assets);
  (* sol cloud: every provider's Terraform roots. *)
  List.iter
    (fun provider ->
       List.iter
         (fun role ->
            let dir = A.cloud_root assets provider role in
            if not (has_terraform dir) then fail "no Terraform root at %s" dir;
            Printf.printf "  ok  terraform  %s\n" (A.cloud_root_rel provider role))
         [ A.Cluster; A.Platform ])
    Sol_cli_provider.all;
  (* sol local infra: each component's values, merged the way the install does. *)
  List.iter
    (fun component ->
       List.iter
         (fun profile ->
            ignore
              (Sol_cli_platform_component.merged_values_yaml ~component ~profile : string))
         [ "local"; "durable" ];
       Printf.printf "  ok  component  %s\n" component)
    (components assets);
  ignore
    (Sol_cli_dev_observability.dashboard_configmap_yaml ~namespace:"monitoring" : string);
  Printf.printf "  ok  dashboards\n";
  ignore (Sol_cli_dev_observability.alloy_values_yaml () : string);
  Printf.printf "  ok  alloy\n";
  (* sol migrate: the runner this sol would use. *)
  (match Cmd_migrate.runner_source () with
   | Error msg -> fail "%s" msg
   | Ok (A.Published image) ->
     Printf.printf "  ok  migration runner  %s (published)\n" image
   | Ok (A.Build_from_source { context }) ->
     Printf.printf "  ok  migration runner  built from %s\n" context);
  Printf.printf "\nall assets present\n"
;;

let cmd =
  Cmd.v
    (Cmd.info
       "assets"
       ~doc:
         "Show where this sol's own assets come from (a source checkout, or an installed \
          release's bundle) and check every one its commands read: the cloud Terraform \
          roots, the local platform components' values, the observability dashboards and \
          Alloy config, and the migration runner. Needs no cluster or cloud account.")
    Term.(const run $ const ())
;;
