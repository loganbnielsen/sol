open Cmdliner
open Sol_cli_scaffold_templates

let subst = Sol_cli_scaffold.subst
let write  = Sol_cli_scaffold.write_file
let link   = Sol_cli_scaffold.link_dir
let norm   = Sol_cli_scaffold.normalize
let cap    = Sol_cli_scaffold.capitalize_name

let is_sol_home dir =
  Sys.file_exists (Filename.concat dir "framework/sol-svc/lib/dune")
  && Sys.file_exists (Filename.concat dir "integrations/kafka/kafka-eio-service/lib/dune")

let rec realpath path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
  in
  try
    let target = Unix.readlink path in
    let target =
      if Filename.is_relative target then Filename.concat (Filename.dirname path) target
      else target
    in
    realpath target
  with Unix.Unix_error ((Unix.EINVAL | Unix.ENOENT), _, _) -> path

let rec find_ancestor pred dir =
  if pred dir then Some dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else find_ancestor pred parent

let infer_sol_home () =
  match Sys.getenv_opt "SOL_HOME" with
  | Some dir when is_sol_home dir -> Some dir
  | Some "" | None ->
    (* An empty string is the closest thing OCaml's Unix.putenv has to
       "unset" (there's no portable unsetenv) -- CODE_LAYER-006 found this
       the hard way when a test's own cleanup left SOL_HOME="" behind for
       a later test in the same process. Treat it the same as truly unset
       rather than as an explicit (and here, always-invalid) override. *)
    let exe =
      try Unix.readlink "/proc/self/exe"
      with Unix.Unix_error _ -> Sys.executable_name
    in
    find_ancestor is_sol_home (Filename.dirname (realpath exe))
  | Some _ -> None  (* invalid SOL_HOME — NOTE in new_workspace covers this *)

let link_sol_sources workspace =
  match infer_sol_home () with
  | None -> false
  | Some sol_home ->
    link ~path:(workspace ^ "/vendor/framework")
      ~target:(Filename.concat sol_home "framework");
    link ~path:(workspace ^ "/vendor/integrations")
      ~target:(Filename.concat sol_home "integrations");
    true

(* ── Command implementations ─────────────────────────────────────────────── *)

let new_workspace name =
  let name = norm name in
  if Sys.file_exists name then begin
    Printf.eprintf "error: %S already exists\n" name;
    exit 1
  end;
  Printf.printf "\nScaffolding workspace %S ...\n\n" name;
  let v = [("name", name); ("Name", cap name)] in
  (* root files *)
  write ~path:(name ^ "/.ocamlformat") ~content:tpl_ocamlformat;
  write ~path:(name ^ "/dune-project") ~content:tpl_dune_project;
  write ~path:(name ^ "/README.md")    ~content:(subst v tpl_readme);
  write ~path:(name ^ "/.github/workflows/deploy.yml") ~content:(subst v tpl_github_deploy);
  write ~path:(name ^ "/.github/workflows/sol-ci.yml") ~content:(subst v tpl_github_ci);
  (* events — also emit sol.toml so topics are discoverable without ML scanning *)
  write ~path:(name ^ "/events/payments/charged.ml")       ~content:(subst v ws_charged_ml);
  write ~path:(name ^ "/events/payments/dune")             ~content:(subst v ws_events_dune);
  write ~path:(name ^ "/events/payments/sol.toml")
    ~content:(subst (v @ [("team", "payments"); ("name", name ^ "-payments-charges")])
                tpl_event_sol_toml);
  (* shared storage lib — Notification module used by svc and worker *)
  write ~path:(name ^ "/lib/notification.ml") ~content:(subst v ws_notification_ml);
  write ~path:(name ^ "/lib/dune")            ~content:(subst v ws_storage_dune);
  (* charge-svc *)
  write ~path:(name ^ "/app/payments/charge_svc/lib/handler.ml")  ~content:(subst v ws_svc_handler_ml);
  write ~path:(name ^ "/app/payments/charge_svc/lib/dune")        ~content:(subst v ws_svc_lib_dune);
  write ~path:(name ^ "/app/payments/charge_svc/bin/main.ml")     ~content:(subst v ws_svc_bin_ml);
  write ~path:(name ^ "/app/payments/charge_svc/bin/dune")        ~content:(subst v ws_svc_bin_dune);
  write ~path:(name ^ "/app/payments/charge_svc/sol.toml")        ~content:tpl_sol_toml;
  write ~path:(name ^ "/app/payments/charge_svc/Dockerfile")
    ~content:(subst (v @ [
      ("repo_dir", "app/payments/charge_svc");
      ("binary",   name ^ "-charge-svc");
    ]) tpl_dockerfile);
  (* notify-worker *)
  write ~path:(name ^ "/app/comms/notify_worker/lib/notify_worker.ml") ~content:(subst v ws_worker_ml);
  write ~path:(name ^ "/app/comms/notify_worker/lib/dune")             ~content:(subst v ws_worker_lib_dune);
  write ~path:(name ^ "/app/comms/notify_worker/bin/main.ml")          ~content:(subst v ws_worker_bin_ml);
  write ~path:(name ^ "/app/comms/notify_worker/bin/dune")             ~content:(subst v ws_worker_bin_dune);
  write ~path:(name ^ "/app/comms/notify_worker/sol.toml")             ~content:tpl_sol_toml;
  write ~path:(name ^ "/app/comms/notify_worker/Dockerfile")
    ~content:(subst (v @ [
      ("repo_dir", "app/comms/notify_worker");
      ("binary",   name ^ "-notify-worker");
    ]) tpl_dockerfile);
  write ~path:(name ^ "/.dockerignore") ~content:tpl_dockerignore;
  (* deploy target placeholder — sol deploy refuses to run without one *)
  write ~path:(name ^ "/sol/prod/aws/us-east-1.yml") ~content:tpl_deploy_target;
  (* db *)
  write ~path:(name ^ "/db/migrations/0001_notifications.sql") ~content:(subst v ws_migration_sql);
  write ~path:(name ^ "/db/migrations/0001_notifications.down.sql") ~content:(subst v ws_migration_down_sql);
  (* schema compatibility test *)
  write ~path:(name ^ "/test/test_schemas.ml") ~content:(subst v ws_test_schemas_ml);
  write ~path:(name ^ "/test/dune")            ~content:(subst v ws_test_dune);
  let linked = link_sol_sources name in
  Printf.printf {|
Done. 28 files generated.

  cd %s
  eval $(opam env) && dune build   # verify the scaffold compiles
  sol dev up           # provision local k3d cluster + infra (first time ~5 min)
  sol up               # build images, push, deploy  (~1 min after first run)
  sol migrate                          # apply DB migrations
  sol status           # check pods + see port-forward hint for charge-svc

  CI/CD: set REGISTRY + REGISTRY_USER + REGISTRY_PASSWORD secrets in GitHub, then
         push to main — .github/workflows/sol-ci.yml handles build/test/deploy.
         sol/prod/aws/us-east-1.yml is a placeholder deploy target — rename
         it to your real <env>/<provider>/<region> and set the SOL_TARGET
         repository variable to match before your first 'sol deploy'.
|} name;
  if not linked then
    Printf.printf {|
NOTE: Sol framework source not found — vendor/ links were not created.
  Set SOL_HOME to your Sol checkout and re-run sol new workspace, or
  create the links manually:

    export SOL_HOME=/path/to/sol
    ln -sf $SOL_HOME/framework %s/vendor/framework
    ln -sf $SOL_HOME/integrations %s/vendor/integrations

  Without these links, dune build will fail with "Library not found".
|} name name

let parse_domain_name arg =
  match String.split_on_char '/' arg with
  | [domain; name] when domain <> "" && name <> "" -> Ok (norm domain, norm name)
  | _ ->
    Error (Printf.sprintf "expected domain/name (e.g. payments/charge), got %S" arg)

let domain_name_or_exit arg =
  match parse_domain_name arg with
  | Ok parsed -> parsed
  | Error msg ->
    Printf.eprintf "error: %s\n" msg;
    exit 1

let ws_of_cwd () = norm (Filename.basename (Sys.getcwd ()))

type component_kind =
  | Service
  | Worker
  | Function

type component_scaffold = {
  kind_label : string;
  dir : string;
  lib : string;
  mod_ : string;
  binary : string;
  files : (string * string) list;
}

let component_suffix = function
  | Service -> "svc"
  | Worker -> "worker"
  | Function -> "fn"

let component_module kind name =
  match kind with
  | Service -> "Handler"
  | Worker -> cap name ^ "_worker"
  | Function -> cap name ^ "_fn"

let component_scaffold kind ~ws ~domain ~name =
  let suffix = component_suffix kind in
  let dir = Printf.sprintf "app/%s/%s_%s" domain name suffix in
  let lib = Printf.sprintf "%s_%s_%s_%s" ws domain name suffix in
  let mod_ = component_module kind name in
  let binary = name ^ "-" ^ suffix in
  let v = [
    ("lib", lib);
    ("dir", dir);
    ("repo_dir", dir);
    ("name", name);
    ("domain", domain);
    ("Mod", mod_);
    ("binary", binary);
  ] in
  let files =
    match kind with
    | Service -> [
        ("lib/handler.ml", svc_handler_ml);
        ("lib/dune", subst v svc_lib_dune);
        ("bin/main.ml", subst v svc_bin_ml);
        ("bin/dune", subst v svc_bin_dune);
        ("sol.toml", tpl_sol_toml);
        ("Dockerfile", subst v tpl_dockerfile);
      ]
    | Worker -> [
        ("lib/" ^ name ^ "_worker.ml", subst v worker_lib_ml);
        ("lib/dune", subst v worker_lib_dune);
        ("bin/main.ml", subst v worker_bin_ml);
        ("bin/dune", subst v worker_bin_dune);
        ("sol.toml", tpl_sol_toml);
        ("Dockerfile", subst v tpl_dockerfile);
      ]
    | Function -> [
        ("lib/" ^ name ^ "_fn.ml", subst v fn_lib_ml);
        ("lib/dune", subst v fn_lib_dune);
        ("bin/main.ml", subst v fn_bin_ml);
        ("bin/dune", subst v fn_bin_dune);
        ("sol.toml", tpl_fn_sol_toml);
        ("Dockerfile", subst v tpl_dockerfile);
      ]
  in
  { kind_label = suffix; dir; lib; mod_; binary; files }

let write_component scaffold =
  List.iter (fun (rel_path, content) ->
    write ~path:(Filename.concat scaffold.dir rel_path) ~content
  ) scaffold.files

let new_svc arg =
  let ws = ws_of_cwd () in
  let domain, name = domain_name_or_exit arg in
  let scaffold = component_scaffold Service ~ws ~domain ~name in
  Printf.printf "\nScaffolding svc %s/%s_svc ...\n\n" domain name;
  write_component scaffold;
  Printf.printf "\nDone.  Build: dune build %s/bin/main.exe\n" scaffold.dir

let new_worker arg =
  let ws = ws_of_cwd () in
  let domain, name = domain_name_or_exit arg in
  let scaffold = component_scaffold Worker ~ws ~domain ~name in
  Printf.printf "\nScaffolding worker %s/%s_worker ...\n\n" domain name;
  write_component scaffold;
  Printf.printf "\nDone.  Replace the stub Message module with your event module, then:\n";
  Printf.printf "  dune build %s/bin/main.exe\n" scaffold.dir

let new_fn arg =
  let ws = ws_of_cwd () in
  let domain, name = domain_name_or_exit arg in
  let scaffold = component_scaffold Function ~ws ~domain ~name in
  Printf.printf "\nScaffolding fn %s/%s_fn ...\n\n" domain name;
  write_component scaffold;
  Printf.printf "\nDone.  Build: dune build %s/bin/main.exe\n" scaffold.dir

(* Append [new_mod] to the "(modules ...)" stanza in [path].
   Handles the standard single-line form "(modules Foo Bar)". *)
let patch_modules_stanza path new_mod =
  let ic = open_in path in
  let content = In_channel.input_all ic in
  close_in ic;
  let prefix = "(modules " in
  let plen = String.length prefix in
  let clen = String.length content in
  let rec find_prefix i =
    if i > clen - plen then None
    else if String.sub content i plen = prefix then Some (i + plen)
    else find_prefix (i + 1)
  in
  match find_prefix 0 with
  | None ->
    Printf.printf "  note: could not locate (modules ...) in %s — add %s manually\n" path new_mod
  | Some pos ->
    let rec find_close i depth =
      if i >= clen then clen
      else match content.[i] with
        | '(' -> find_close (i + 1) (depth + 1)
        | ')' -> if depth = 0 then i else find_close (i + 1) (depth - 1)
        | _   -> find_close (i + 1) depth
    in
    let close = find_close pos 0 in
    let updated =
      String.sub content 0 close
      ^ " " ^ new_mod
      ^ String.sub content close (clen - close)
    in
    let oc = open_out path in
    output_string oc updated;
    close_out oc;
    Printf.printf "  updated %s\n" path

let new_event arg =
  let ws = ws_of_cwd () in
  let team, name = domain_name_or_exit arg in
  let file       = Printf.sprintf "events/%s/%s.ml"      team name in
  let dune_f     = Printf.sprintf "events/%s/dune"        team in
  let toml_f     = Printf.sprintf "events/%s/sol.toml"    team in
  let mod_    = cap name in
  let lib     = ws ^ "_" ^ team ^ "_events" in
  let v = [("team", team); ("name", name); ("Mod", mod_); ("lib", lib)] in
  Printf.printf "\nScaffolding event %s/%s ...\n\n" team name;
  if Sys.file_exists file then begin
    Printf.eprintf "error: %S already exists\n" file;
    exit 1
  end;
  write ~path:file ~content:(subst v event_ml);
  if Sys.file_exists dune_f then
    patch_modules_stanza dune_f mod_
  else begin
    write ~path:dune_f ~content:(subst v {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules {{Mod}})
 (libraries kafka_eio_service yojson))
|tpl});
  end;
  (* Leave an existing sol.toml intact (operator may have added more topics);
     a new one lists just this event's default topic. *)
  if not (Sys.file_exists toml_f) then
    write ~path:toml_f ~content:(subst v tpl_event_sol_toml);
  Printf.printf "\nDone.  Consumers add (libraries %s) to their dune files.\n" lib

(* ── Cmdliner terms ───────────────────────────────────────────────────────── *)

let name_arg docv doc =
  Arg.(required & pos 0 (some string) None & info [] ~docv ~doc)

let workspace_cmd =
  Cmd.v
    (Cmd.info "workspace" ~doc:"Scaffold a new Sol workspace with a working two-service example")
    Term.(const new_workspace $ name_arg "NAME" "Workspace name, e.g. acme")

let svc_cmd =
  Cmd.v
    (Cmd.info "svc" ~doc:"Add an HTTP service to the current workspace")
    Term.(const new_svc $ name_arg "DOMAIN/NAME" "e.g. payments/charge")

let worker_cmd =
  Cmd.v
    (Cmd.info "worker" ~doc:"Add a Kafka consumer worker to the current workspace")
    Term.(const new_worker $ name_arg "DOMAIN/NAME" "e.g. comms/notify")

let fn_cmd =
  Cmd.v
    (Cmd.info "fn" ~doc:"Add a scheduled function to the current workspace")
    Term.(const new_fn $ name_arg "DOMAIN/NAME" "e.g. billing/monthly_report")

let event_cmd =
  Cmd.v
    (Cmd.info "event" ~doc:"Add a typed Kafka event contract to the current workspace")
    Term.(const new_event $ name_arg "TEAM/NAME" "e.g. payments/charged")

let cmd =
  Cmd.group
    (Cmd.info "new" ~doc:"Scaffold workspace components")
    [ workspace_cmd; svc_cmd; worker_cmd; fn_cmd; event_cmd ]
