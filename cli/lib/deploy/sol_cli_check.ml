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

let check_workload ~manifest (workload : Sol_cli_workspace_model.workload) =
  let svc = workload.Sol_cli_workspace_model.service in
  let findings = ref [] in
  let add severity path message = findings := { severity; path; message } :: !findings in
  (match workload.Sol_cli_workspace_model.language with
   | Some _ -> ()
   | None ->
     add
       Severity.Warning
       manifest
       (Printf.sprintf
          "%s declares no language; add `language: ocaml` (or typescript) under \
           services.%s in sol.yml"
          svc.Sol_cli_manifest.name
          svc.Sol_cli_manifest.name));
  let dockerfile = Filename.concat svc.Sol_cli_manifest.dir "Dockerfile" in
  if not workload.has_dockerfile
  then add Severity.Error dockerfile "Dockerfile is missing";
  let toml_path = Filename.concat svc.Sol_cli_manifest.dir "sol.toml" in
  (match workload.config with
   | Error err -> add Severity.Error toml_path (Sol_cli_toml.parse_error_to_string err)
   | Ok toml ->
     let check_key kind key =
       if not (valid_env_key key)
       then
         add
           Severity.Error
           toml_path
           (Printf.sprintf
              "invalid %s secret key %S; use uppercase letters, digits, and underscores"
              kind
              key)
     in
     List.iter (check_key "runtime") toml.secret_keys;
     List.iter (check_key "build-time") toml.build_secret_keys;
     (match svc.Sol_cli_manifest.primitive, toml.schedule with
      | Sol_cli_manifest.Fn, _ -> ()
      | (Svc | Worker), Some _ ->
        add
          Severity.Warning
          toml_path
          "[service] schedule is ignored for non-function workloads"
      | _ -> ()));
  List.rev !findings
;;

let same_unit (a : Sol_cli_manifest.service) (b : Sol_cli_manifest.service) =
  String.equal a.domain b.domain && String.equal a.name b.name
;;

let run_services ~facts services =
  facts.Sol_cli_workspace_model.workloads
  |> List.filter (fun (w : Sol_cli_workspace_model.workload) ->
    List.exists (fun svc -> same_unit svc w.Sol_cli_workspace_model.service) services)
  |> List.concat_map (check_workload ~manifest:"sol.yml")
;;

let run ~facts =
  match facts.Sol_cli_workspace_model.app_dir with
  | None ->
    [ { severity = Severity.Error
      ; path = "app"
      ; message =
          Sol_cli_manifest.discover_error_to_string Sol_cli_manifest.Missing_app_dir
      }
    ]
  | Some _ ->
    let warnings = List.map unexpected_finding facts.unexpected in
    let workload_findings =
      List.concat_map (check_workload ~manifest:"sol.yml") facts.workloads
    in
    (match facts.workloads with
     | [] ->
       warnings
       @ [ { severity = Severity.Error
           ; path = "app"
           ; message = "no Sol workloads found with a Dockerfile"
           }
         ]
     | _ :: _ -> warnings @ workload_findings)
;;

let has_errors findings = List.exists is_error findings
