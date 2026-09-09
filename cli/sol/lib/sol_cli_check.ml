module Severity = struct
  type t = Error | Warning
end

type finding = { severity : Severity.t; path : string; message : string }

let severity_to_string = function
  | Severity.Error -> "error"
  | Severity.Warning -> "warning"

let finding_to_string f =
  Printf.sprintf "%s: %s: %s" (severity_to_string f.severity) f.path f.message

let is_error f = f.severity = Severity.Error

let valid_env_key key =
  match Sol_cli_secret.validate_key key with Ok () -> true | Error _ -> false

let normalize_filter = String.map (function '-' -> '_' | c -> c)

let discover_candidates ~filter_path =
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir) then
    Error Sol_cli_manifest.Missing_app_dir
  else begin
    let services = ref [] in
    (try
       Array.iter
         (fun domain ->
           let dp = Filename.concat app_dir domain in
           if domain.[0] <> '.' && Sys.is_directory dp then
             Array.iter
               (fun name ->
                 let dir = Filename.concat dp name in
                 if name.[0] <> '.' && Sys.is_directory dir then
                   match Sol_cli_manifest.primitive_of_suffix name with
                   | None -> ()
                   | Some primitive ->
                       let included =
                         match filter_path with
                         | None -> true
                         | Some p ->
                             let p = normalize_filter p in
                             dir = p || Filename.basename dir = p
                       in
                       if included then
                         services :=
                           { Sol_cli_manifest.domain; name; primitive; dir }
                           :: !services)
               (Sys.readdir dp))
         (Sys.readdir app_dir)
     with _ -> ());
    Ok (List.rev !services)
  end

let check_service (svc : Sol_cli_manifest.service) =
  let findings = ref [] in
  let add severity path message =
    findings := { severity; path; message } :: !findings
  in
  if not (Sys.file_exists svc.dir && Sys.is_directory svc.dir) then
    add Severity.Error svc.dir "service directory is missing";
  let dockerfile = Filename.concat svc.dir "Dockerfile" in
  if not (Sys.file_exists dockerfile) then
    add Severity.Error dockerfile "Dockerfile is missing";
  let toml_path = Filename.concat svc.dir "sol.toml" in
  (match Sol_cli_toml.load_result toml_path with
  | Error err ->
      add Severity.Error toml_path (Sol_cli_toml.parse_error_to_string err)
  | Ok toml -> (
      List.iter
        (fun key ->
          if not (valid_env_key key) then
            add Severity.Error toml_path
              (Printf.sprintf
                 "invalid secret key %S; use uppercase letters, digits, and \
                  underscores"
                 key))
        toml.Sol_cli_toml.secret_keys;
      match (svc.primitive, toml.schedule) with
      | Sol_cli_manifest.Fn, _ -> ()
      | (Svc | Worker), Some _ ->
          add Severity.Warning toml_path
            "[service] schedule is ignored for non-function workloads"
      | _ -> ()));
  List.rev !findings

let run ~filter_path () =
  match discover_candidates ~filter_path with
  | Error err ->
      [
        {
          severity = Severity.Error;
          path = "app";
          message = Sol_cli_manifest.discover_error_to_string err;
        };
      ]
  | Ok services when services = [] ->
      [
        {
          severity = Severity.Error;
          path = "app";
          message = "no Sol workloads found with a Dockerfile";
        };
      ]
  | Ok services -> List.concat_map check_service services

let has_errors findings = List.exists is_error findings
