module Severity = struct
  type t =
    | Error
    | Warning
end

type finding =
  { severity : Severity.t
  ; path : string
  ; message : string
  }

let severity_to_string = function
  | Severity.Error -> "error"
  | Severity.Warning -> "warning"
;;

let finding_to_string f =
  Printf.sprintf "%s: %s: %s" (severity_to_string f.severity) f.path f.message
;;

let is_error f = f.severity = Severity.Error

let valid_env_key key =
  match Sol_cli_secret.validate_key key with
  | Ok () -> true
  | Error _ -> false
;;

let unexpected_finding ((_domain, _name, dir) : Sol_cli_manifest.unexpected) =
  { severity = Severity.Warning
  ; path = dir
  ; message = "directory does not match a Sol workload suffix (*_svc, *_worker, *_fn)"
  }
;;

let check_service (svc : Sol_cli_manifest.service) =
  let findings = ref [] in
  let add severity path message = findings := { severity; path; message } :: !findings in
  if not (Sys.file_exists svc.dir && Sys.is_directory svc.dir)
  then add Severity.Error svc.dir "service directory is missing";
  let dockerfile = Filename.concat svc.dir "Dockerfile" in
  if not (Sys.file_exists dockerfile)
  then add Severity.Error dockerfile "Dockerfile is missing";
  let toml_path = Filename.concat svc.dir "sol.toml" in
  (match Sol_cli_toml.load_result toml_path with
   | Error err -> add Severity.Error toml_path (Sol_cli_toml.parse_error_to_string err)
   | Ok toml ->
     List.iter
       (fun key ->
          if not (valid_env_key key)
          then
            add
              Severity.Error
              toml_path
              (Printf.sprintf
                 "invalid secret key %S; use uppercase letters, digits, and underscores"
                 key))
       toml.Sol_cli_toml.secret_keys;
     (match svc.primitive, toml.schedule with
      | Sol_cli_manifest.Fn, _ -> ()
      | (Svc | Worker), Some _ ->
        add
          Severity.Warning
          toml_path
          "[service] schedule is ignored for non-function workloads"
      | _ -> ()));
  List.rev !findings
;;

let run ~filter_path () =
  match Sol_cli_manifest.scan_workspace ~filter_path with
  | Error err ->
    [ { severity = Severity.Error
      ; path = "app"
      ; message = Sol_cli_manifest.discover_error_to_string err
      }
    ]
  | Ok scan when scan.workloads = [] ->
    let warnings = List.map unexpected_finding scan.unexpected in
    warnings
    @ [ { severity = Severity.Error
        ; path = "app"
        ; message = "no Sol workloads found with a Dockerfile"
        }
      ]
  | Ok scan ->
    let warnings = List.map unexpected_finding scan.unexpected in
    let workload_findings =
      List.concat_map
        (fun w -> check_service (Sol_cli_manifest.workload_fact_to_service w))
        scan.workloads
    in
    warnings @ workload_findings
;;

let has_errors findings = List.exists is_error findings
