(* REFAC-130: the check is a projection of the workspace model. It used to walk
   [app/] itself and re-read every workload's [sol.toml] -- the third reader of
   the same facts -- while the command that called it had already read them. The
   findings below are now derived from the model the caller loaded once. *)

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

(* The workload's own files. [paths] stay workspace-root relative, which is what
   the command's cwd has been since [Sol_cli_workspace.enter_cwd]. *)
let check_workload (workload : Sol_cli_workspace_model.workload) =
  let svc = workload.Sol_cli_workspace_model.service in
  let findings = ref [] in
  let add severity path message = findings := { severity; path; message } :: !findings in
  let dockerfile = Filename.concat svc.Sol_cli_manifest.dir "Dockerfile" in
  if not workload.has_dockerfile
  then add Severity.Error dockerfile "Dockerfile is missing";
  let toml_path = Filename.concat svc.Sol_cli_manifest.dir "sol.toml" in
  (match workload.config with
   | Error err -> add Severity.Error toml_path (Sol_cli_toml.parse_error_to_string err)
   | Ok toml ->
     toml.secret_keys
     |> List.iter (fun key ->
       if not (valid_env_key key)
       then
         add
           Severity.Error
           toml_path
           (Printf.sprintf
              "invalid secret key %S; use uppercase letters, digits, and underscores"
              key));
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

(* Check exactly the workloads a command resolved. Selection has already
   happened by the time a command calls this (FEAT-065), so a scoped [sol up]
   inspects the same set it is about to mutate. The selection was resolved from
   [facts], so this is a filter over the model rather than a lookup that could
   disagree with it. *)
let run_services ~facts services =
  facts.Sol_cli_workspace_model.workloads
  |> List.filter (fun (w : Sol_cli_workspace_model.workload) ->
    List.exists (fun svc -> same_unit svc w.Sol_cli_workspace_model.service) services)
  |> List.concat_map check_workload
;;

(* The whole-workspace check: report unexpected directories as warnings, and fail
   when the workspace has no workload directory at all. An [app/] that is not
   there is named as such rather than reported as an empty one. *)
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
    let workload_findings = List.concat_map check_workload facts.workloads in
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
