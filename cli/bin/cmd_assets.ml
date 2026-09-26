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

let ( let* ) = Result.bind

(* One check: what it covers, and either what it found or why it failed. *)
type check =
  { label : string
  ; outcome : (string, string) result
  }

let check label outcome = { label; outcome }
let as_detail detail = Result.map (fun _ -> detail)

let terraform_root assets provider role =
  let dir = A.cloud_root assets provider role in
  let has_terraform =
    Sys.file_exists dir
    && Sys.is_directory dir
    && Array.exists (fun f -> Filename.check_suffix f ".tf") (Sys.readdir dir)
  in
  check
    "terraform"
    (if has_terraform
     then Ok (A.cloud_root_rel provider role)
     else Error ("no Terraform root at " ^ dir))
;;

let component_names assets =
  let path = A.components_json assets in
  match Yojson.Safe.from_file path with
  | `Assoc fields -> Ok (List.map fst fields)
  | _ -> Error (path ^ " is not a JSON object")
  | exception Yojson.Json_error msg -> Error (path ^ ": " ^ msg)
  | exception Sys_error msg -> Error msg
;;

(* sol local infra: each component's values, merged the way the install does. *)
let component_checks assets =
  match component_names assets with
  | Error reason -> [ check "components" (Error reason) ]
  | Ok names ->
    names
    |> List.map (fun component ->
      check
        "component"
        (let* _ =
           Sol_cli_platform_component.merged_values_yaml
             ~assets
             ~component
             ~profile:"local"
         in
         Sol_cli_platform_component.merged_values_yaml
           ~assets
           ~component
           ~profile:"durable"
         |> as_detail component))
;;

let runner_check () =
  check
    "migration runner"
    (Cmd_migrate.runner_source ()
     |> Result.map (function
       | A.Published image -> image ^ " (published)"
       | A.Build_from_source { context } -> "built from " ^ context))
;;

(* Every check the commands' own code would make, run through that code. *)
let checks assets =
  List.concat
    [ Sol_cli_provider.all
      |> List.concat_map (fun provider ->
        [ A.Cluster; A.Platform ] |> List.map (terraform_root assets provider))
    ; component_checks assets
    ; [ check
          "dashboards"
          (Sol_cli_dev_observability.dashboard_configmap_yaml
             ~assets
             ~namespace:"monitoring"
           |> as_detail "")
      ; check "alloy" (Sol_cli_dev_observability.alloy_values_yaml ~assets |> as_detail "")
      ; runner_check ()
      ]
    ]
;;

let print_check { label; outcome } =
  match outcome with
  | Ok "" -> Printf.printf "  ok  %s\n" label
  | Ok detail -> Printf.printf "  ok  %s  %s\n" label detail
  | Error reason -> Printf.printf "  FAIL  %s  %s\n" label reason
;;

let run () =
  let* assets =
    A.resolve () |> Result.map_error (fun e -> Sol_cli_exit.error (A.error_to_string e))
  in
  Printf.printf
    "sol %s\nassets: %s\n  root: %s\n\n%!"
    (Option.value Sol_cli_build_info.release_version ~default:Version.v)
    (form_to_string assets)
    (A.dir assets);
  let checks = checks assets in
  checks |> List.iter print_check;
  match List.filter (fun c -> Result.is_error c.outcome) checks with
  | [] ->
    Printf.printf "\nall assets present\n";
    Ok ()
  | failed ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "%d of %d asset checks failed"
            (List.length failed)
            (List.length checks)))
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
    Term.(const (fun () -> Sol_cli_exit.exit_on (run ())) $ const ())
;;
