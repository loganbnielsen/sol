open Cmdliner

let norm = Sol_cli_scaffold.normalize
let cap = Sol_cli_scaffold.capitalize_name

module Tree = Sol_cli_scaffold_tree
module Assets = Sol_cli_platform_assets
open Result.Syntax

let always_write _ = Tree.Write

let template_root () =
  let* assets =
    Assets.resolve () |> Result.map_error (fun error -> Assets.error_to_string error)
  in
  Ok (Assets.templates_root assets)
;;

let copy ~kind ~dest ~vars ~rule =
  let* root = template_root () in
  Tree.copy ~root ~kind ~dest ~vars ~rule
;;

let workspace_vars ~name rel =
  let v = [ "name", name; "Name", cap name; "basename", Filename.basename name ] in
  match rel with
  | "events/payments/sol.toml" -> ("team", "payments") :: v
  | "app/payments/charge_svc/Dockerfile" ->
    ("repo_dir", "app/payments/charge_svc") :: ("binary", name ^ "-charge-svc") :: v
  | "app/comms/notify_worker/Dockerfile" ->
    ("repo_dir", "app/comms/notify_worker") :: ("binary", name ^ "-notify-worker") :: v
  | _ -> v
;;

let new_workspace name =
  let raw_name = name in
  let name = norm name in
  let* () =
    if Sys.file_exists name
    then Error (Printf.sprintf "%S already exists" name)
    else Ok ()
  in
  Sol_cli_report.app "\nScaffolding workspace %S ...\n" name;
  if name <> raw_name
  then (
    let k8s_name = String.map (fun c -> if c = '_' then '-' else c) name in
    Sol_cli_report.app
      "note: %S is not a valid OCaml/SQL identifier, so it is normalized to %S\n\
       (lowercased, '-' -> '_'). Kubernetes namespaces use the hyphenated form\n\
       again, e.g. %s-payments.\n"
      raw_name
      name
      k8s_name);
  let* written =
    copy ~kind:"workspace" ~dest:name ~vars:(workspace_vars ~name) ~rule:always_write
  in
  Sol_cli_report.app
    {|
Done. %d files generated.

  cd %s
  eval $(opam env) && dune build   # verify the scaffold compiles
  sol local infra up   # provision local k3d cluster + infra (first time ~5 min)
  sol up               # build images, push, deploy  (first build ~5 min if the image cache is cold, ~1 min after)
  sol migrate                          # apply DB migrations
  sol local status     # check pods + see port-forward hint for charge-svc

  Framework dependency: this workspace declares the Sol framework packages in
  %s.opam and resolves them from your opam switch. Nothing is vendored here.
  In development, install the framework from your Sol checkout with:

    bash platform/local/scripts/prepare-framework-deps.sh

  (released users instead declare a version in %s.opam and let opam resolve it).

  CI/CD: set REGISTRY + REGISTRY_USER + REGISTRY_PASSWORD secrets in GitHub, then
         push to main — .github/workflows/sol-ci.yml handles build/test/deploy.
         sol/environments.yml declares a placeholder prod/aws/us-east-1 target —
         rename it to your real <env> and <provider>/<region>, and set the
         SOL_TARGET repository variable to match, before your first 'sol deploy'.|}
    (List.length written)
    name
    name
    name;
  Ok ()
;;

let parse_domain_name arg =
  match String.split_on_char '/' arg with
  | [ domain; name ] when domain <> "" && name <> "" -> Ok (norm domain, norm name)
  | _ -> Error (Printf.sprintf "expected domain/name (e.g. payments/charge), got %S" arg)
;;

let ws_of_cwd () = norm (Filename.basename (Sys.getcwd ()))

type component_kind =
  | Service
  | Worker
  | Function

let component_suffix = function
  | Service -> "svc"
  | Worker -> "worker"
  | Function -> "fn"
;;

let component_module kind name =
  match kind with
  | Service -> "Handler"
  | Worker -> cap name ^ "_worker"
  | Function -> cap name ^ "_fn"
;;

let component_vars kind ~ws ~domain ~name =
  let suffix = component_suffix kind in
  let dir = Printf.sprintf "app/%s/%s_%s" domain name suffix in
  let lib = Printf.sprintf "%s_%s_%s_%s" ws domain name suffix in
  [ "lib", lib
  ; "dir", dir
  ; "repo_dir", dir
  ; "name", name
  ; "domain", domain
  ; "Mod", component_module kind name
  ; "binary", name ^ "-" ^ suffix
  ; "basename", Filename.basename ws
  ]
;;

let new_component kind ~label arg =
  let ws = ws_of_cwd () in
  let* domain, name = parse_domain_name arg in
  let suffix = component_suffix kind in
  let dir = Printf.sprintf "app/%s/%s_%s" domain name suffix in
  let* root =
    Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
    |> Result.map_error Sol_cli_workspace.workspace_error_to_string
  in
  let unit_name = Filename.basename dir in
  let* declaration =
    Sol_cli_sol_yml.plan ~root ~name:unit_name ~dir ~language:Sol_cli_compat.Ocaml
  in
  Sol_cli_report.app "\nScaffolding %s %s/%s_%s ...\n" label domain name suffix;
  let vars = component_vars kind ~ws ~domain ~name in
  let* _ = copy ~kind:suffix ~dest:dir ~vars:(fun _ -> vars) ~rule:always_write in
  let* outcome = Sol_cli_sol_yml.commit declaration in
  (match outcome with
   | Sol_cli_sol_yml.Declared ->
     Sol_cli_report.app "  sol.yml: added %s, declared language: ocaml" unit_name
   | Sol_cli_sol_yml.Language_added ->
     Sol_cli_report.app "  sol.yml: declared language: ocaml for %s" unit_name
   | Sol_cli_sol_yml.Already_declared ->
     Sol_cli_report.app "  sol.yml: %s already declares language: ocaml" unit_name);
  Ok dir
;;

let new_svc arg =
  let* dir = new_component Service ~label:"svc" arg in
  Sol_cli_report.app "\nDone.  Build: dune build %s/bin/main.exe" dir;
  Ok ()
;;

let new_worker arg =
  let* dir = new_component Worker ~label:"worker" arg in
  Sol_cli_report.app
    "\nDone.  Replace the stub Message module with your event module, then:";
  Sol_cli_report.app "  dune build %s/bin/main.exe" dir;
  Ok ()
;;

let new_fn arg =
  let* dir = new_component Function ~label:"fn" arg in
  Sol_cli_report.app "\nDone.  Build: dune build %s/bin/main.exe" dir;
  Ok ()
;;

let event_vars ~ws ~team ~name =
  [ "team", team; "name", name; "Mod", cap name; "lib", ws ^ "_" ^ team ^ "_events" ]
;;

let event_rule module_ = function
  | "events/{{team}}/dune" -> Tree.Patch_modules module_
  | "events/{{team}}/sol.toml" -> Tree.Skip_if_exists
  | _ -> Tree.Write
;;

let new_event arg =
  let ws = ws_of_cwd () in
  let* team, name = parse_domain_name arg in
  let file = Printf.sprintf "events/%s/%s.ml" team name in
  let lib = ws ^ "_" ^ team ^ "_events" in
  Sol_cli_report.app "\nScaffolding event %s/%s ...\n" team name;
  let* () =
    if Sys.file_exists file
    then Error (Printf.sprintf "%S already exists" file)
    else Ok ()
  in
  let vars = event_vars ~ws ~team ~name in
  let* _ =
    copy ~kind:"event" ~dest:"." ~vars:(fun _ -> vars) ~rule:(event_rule (cap name))
  in
  Sol_cli_report.app "\nDone.  Consumers add (libraries %s) to their dune files." lib;
  Ok ()
;;

let run scaffold arg = Sol_cli_exit.exit_on (scaffold arg |> Sol_cli_exit.of_msg)

let name_arg docv doc =
  Arg.(required & pos 0 (some Sol_cli_args.text) None & info [] ~docv ~doc)
;;

let workspace_cmd =
  Cmd.v
    (Cmd.info
       "workspace"
       ~doc:"Scaffold a new Sol workspace with a working two-service example")
    Term.(const (run new_workspace) $ name_arg "NAME" "Workspace name, e.g. acme")
;;

let svc_cmd =
  Cmd.v
    (Cmd.info "svc" ~doc:"Add an HTTP service to the current workspace")
    Term.(const (run new_svc) $ name_arg "DOMAIN/NAME" "e.g. payments/charge")
;;

let worker_cmd =
  Cmd.v
    (Cmd.info "worker" ~doc:"Add a Kafka consumer worker to the current workspace")
    Term.(const (run new_worker) $ name_arg "DOMAIN/NAME" "e.g. comms/notify")
;;

let fn_cmd =
  Cmd.v
    (Cmd.info "fn" ~doc:"Add a scheduled function to the current workspace")
    Term.(const (run new_fn) $ name_arg "DOMAIN/NAME" "e.g. billing/monthly_report")
;;

let event_cmd =
  Cmd.v
    (Cmd.info "event" ~doc:"Add a typed Kafka event contract to the current workspace")
    Term.(const (run new_event) $ name_arg "TEAM/NAME" "e.g. payments/charged")
;;

let cmd =
  Cmd.group
    (Cmd.info "new" ~doc:"Scaffold workspace components")
    [ workspace_cmd; svc_cmd; worker_cmd; fn_cmd; event_cmd ]
;;
