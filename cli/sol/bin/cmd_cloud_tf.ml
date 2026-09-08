(* sol cloud plan/apply/destroy — manage cloud infrastructure via Terraform.
   Requires: terraform binary in PATH, cloud credentials in environment. *)

open Cmdliner

(* ── Sol home resolution ─────────────────────────────────────────────────── *)

(* Resolve the Sol monorepo root so we can locate platform/infra/<provider>/. *)
let resolve_sol_home () =
  match Sol_cli_cmd_new.infer_sol_home () with
  | Some dir -> dir
  | None ->
    Printf.eprintf "error: cannot locate the Sol monorepo root.\n";
    Printf.eprintf "  Set SOL_HOME to your Sol checkout and re-run:\n";
    Printf.eprintf "    export SOL_HOME=/path/to/sol\n";
    exit 1

(* ── Terraform output parsing ───────────────────────────────────────────── *)

(* Read terraform output -json from a temp file and print key endpoints.
   We only print non-sensitive string/list values. *)
let print_outputs infra_dir =
  match Sol_cli_terraform.output_json ~chdir:infra_dir with
  | Error _ | Ok { Sol_cli_process.exit_code = (1 | 2 | 127 | 128); _ } ->
    Printf.printf "  (could not retrieve terraform outputs)\n%!"
  | Ok r when r.Sol_cli_process.exit_code <> 0 ->
    Printf.printf "  (could not retrieve terraform outputs)\n%!"
  | Ok r ->
    (try
      let print_output_field key obj =
        match obj with
        | `Assoc fields ->
          let sensitive = match List.assoc_opt "sensitive" fields with
            | Some (`Bool b) -> b
            | _ -> true
          in
          if not sensitive then
            (match List.assoc_opt "value" fields with
             | Some (`String v) ->
               Printf.printf "  %-28s  %s\n%!" key v
             | Some (`List vs) ->
               let strs = List.filter_map (function `String s -> Some s | _ -> None) vs in
               if strs <> [] then
                 Printf.printf "  %-28s  [%s]\n%!" key (String.concat ", " strs)
             | Some `Null ->
               Printf.printf "  %-28s  (none)\n%!" key
             | _ -> ())
        | _ -> ()
      in
      let json = Yojson.Safe.from_string r.Sol_cli_process.stdout in
      (match json with
       | `Assoc pairs -> List.iter (fun (key, obj) -> print_output_field key obj) pairs
       | _ -> ())
    with _ ->
      Printf.printf "  (error parsing terraform outputs)\n%!")

(* ── cloud apply/plan ───────────────────────────────────────────────────── *)

type provider = Aws | Gcp

let provider_name = function Aws -> "aws" | Gcp -> "gcp"

let provider_of_target_path target =
  match String.split_on_char '/' target with
  | [_env; "aws"; _region] -> Aws
  | [_env; "gcp"; _region] -> Gcp
  | [_env; provider; _region] ->
    Printf.eprintf "error: unsupported provider %S in target %S.\n" provider target;
    exit 1
  | _ ->
    Printf.eprintf "error: target must look like <env>/<provider>/<region>.\n";
    exit 1

let check_terraform () =
  if not (Sol_cli_terraform.which_check ()) then begin
    Printf.eprintf "error: %S not found in PATH.\n" "terraform";
    Printf.eprintf "  Install: %s\n" "https://developer.hashicorp.com/terraform/install";
    exit 1
  end

let infra_dir provider =
  let pname = provider_name provider in
  let sol_home = resolve_sol_home () in
  let dir = Filename.concat sol_home
    (Printf.sprintf "platform/infra/%s" pname) in
  if not (Sys.file_exists dir) then begin
    Printf.eprintf "error: Terraform module not found: %s\n" dir;
    exit 1
  end;
  pname, dir

type action = Plan | Apply

let action_of_flags plan apply =
  match plan, apply with
  | true, false  -> `Ok Plan
  | false, true  -> `Ok Apply
  | false, false -> `Ok Plan
  | true, true   -> `Error (false, "--plan and --apply are mutually exclusive")

let exit_code_of r = match r with
  | Ok r -> r.Sol_cli_process.exit_code
  | Error _ -> 1

(* Full stdout/stderr already went to this run's phase log via
   Sol_cli_run_log.run_phase, which also printed the compact status line and,
   on failure, the log path and its tail. Nothing left to print here. *)
let require_terraform_success r =
  match r with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> ()
  | _ -> exit 1

let normalize_var_file path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

let trim_quotes s =
  let s = String.trim s in
  let len = String.length s in
  if len >= 2 && s.[0] = '"' && s.[len - 1] = '"' then
    String.sub s 1 (len - 2)
  else s

let var_value key vars =
  List.find_map (fun v ->
    match String.index_opt v '=' with
    | None -> None
    | Some i ->
      if String.sub v 0 i |> String.trim = key then
        Some (String.sub v (i + 1) (String.length v - i - 1) |> trim_quotes)
      else None
  ) (List.rev vars)

let var_file_value key path =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let rec loop () =
           match input_line ic with
           | line ->
             let line = String.trim line in
             if line = "" || line.[0] = '#' then loop ()
             else
               (match String.index_opt line '=' with
                | None -> loop ()
                | Some i ->
                  if String.sub line 0 i |> String.trim = key then
                    Some (String.sub line (i + 1) (String.length line - i - 1) |> trim_quotes)
                  else loop ())
           | exception End_of_file -> None
         in
         loop ())
  with _ -> None

let resolved_var key ~var_files ~vars ~default =
  match var_value key vars with
  | Some _ as v -> v
  | None ->
    match List.find_map (var_file_value key) var_files with
    | Some _ as v -> v
    | None -> default

let contains ~needle s =
  let nlen = String.length needle in
  let slen = String.length s in
  let rec loop i =
    i + nlen <= slen &&
    (String.sub s i nlen = needle || loop (i + 1))
  in
  nlen = 0 || loop 0

let aws_absent ~region ~kind ~missing_marker ~argv =
  match Sol_cli_process.run (Sol_cli_process.cmd ("aws" :: argv @ ["--region"; region])) with
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    Printf.eprintf "error: AWS %s still exists after destroy.\n" kind;
    false
  | Ok r when contains ~needle:missing_marker r.Sol_cli_process.stderr -> true
  | Ok r ->
    Printf.eprintf "error: AWS %s verification failed: %s\n" kind r.Sol_cli_process.stderr;
    false
  | Error _ ->
    Printf.eprintf "error: AWS %s verification failed: aws CLI unavailable.\n" kind;
    false

let workspace_name () = Filename.basename (Sys.getcwd ())

let aws_no_ecr_repositories ~region ~workspace_name =
  let prefix = workspace_name ^ "/" in
  let query =
    Printf.sprintf "repositories[?starts_with(repositoryName, `%s`)].repositoryName" prefix
  in
  match Sol_cli_process.run
          (Sol_cli_process.cmd
             ["aws"; "ecr"; "describe-repositories"; "--query"; query;
              "--output"; "text"; "--region"; region])
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 && String.trim r.Sol_cli_process.stdout = "" -> true
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    Printf.eprintf "error: AWS ECR repositories still exist after destroy: %s\n"
      r.Sol_cli_process.stdout;
    false
  | Ok r ->
    Printf.eprintf "error: AWS ECR verification failed: %s\n" r.Sol_cli_process.stderr;
    false
  | Error _ ->
    Printf.eprintf "error: AWS ECR verification failed: aws CLI unavailable.\n";
    false

let verify_aws_destroy ~var_files ~vars =
  match resolved_var "cluster_name" ~var_files ~vars ~default:None with
  | None ->
    Printf.eprintf "error: cannot verify AWS destroy without cluster_name.\n";
    Printf.eprintf "  Pass the same --var cluster_name=... or --var-file used for init.\n";
    exit 1
  | Some cluster_name ->
    let region = Option.value
      (resolved_var "region" ~var_files ~vars ~default:(Some "us-east-1"))
      ~default:"us-east-1"
    in
    let eks_gone =
      aws_absent ~region ~kind:"EKS cluster"
        ~missing_marker:"ResourceNotFoundException"
        ~argv:["eks"; "describe-cluster"; "--name"; cluster_name]
    in
    let rds_gone =
      aws_absent ~region ~kind:"RDS instance"
        ~missing_marker:"DBInstanceNotFound"
        ~argv:["rds"; "describe-db-instances"; "--db-instance-identifier"; cluster_name ^ "-postgres"]
    in
    let workspace_name =
      Option.value
        (resolved_var "workspace_name" ~var_files ~vars ~default:None)
        ~default:(workspace_name ())
    in
    let ecr_gone = aws_no_ecr_repositories ~region ~workspace_name in
    if not (eks_gone && rds_gone && ecr_gone) then exit 1;
    Printf.printf "  AWS verification passed: EKS/RDS/ECR not found.\n%!"

let run_terraform_init run_log infra_dir =
  require_terraform_success
    (Sol_cli_run_log.run_phase run_log ~name:"terraform-init"
       (fun () -> Sol_cli_terraform.init ~chdir:infra_dir))

let config_vars ~strict target =
  match target with
  | None -> [], None
  | Some target_path ->
    match Sol_cli_config.load_for_target ~target:target_path with
    | Error e ->
      Printf.eprintf "error: %s\n" (Sol_cli_config.error_to_string e);
      exit 1
    | Ok cfg ->
      match Sol_cli_config.target cfg with
      | None ->
        Printf.eprintf "error: target %S not found\n" target_path;
        exit 1
      | Some resolved_target ->
        (* Only Apply/destroy mutate real infrastructure; Plan and
           plan-destroy are previews, matching sol plan's own permissive
           contract. Same reasoning as cmd_deploy.ml's check: a typo'd or
           unintended target must not silently inherit sol.yml's shared
           defaults and terraform apply/destroy anyway. *)
        if strict &&
           not (Sys.file_exists (Sol_cli_config.target_file resolved_target))
        then begin
          Printf.eprintf "error: no %s for target %S -- terraform \
                           apply/destroy require an explicit target file, \
                           even an empty one, so a typo'd or unintended \
                           target can't silently inherit sol.yml's shared \
                           defaults and mutate infrastructure anyway.\n"
            (Sol_cli_config.target_file resolved_target) target_path;
          exit 1
        end;
        match Sol_cli_config.terraform_vars ~workspace:(workspace_name ()) cfg with
        | Error msg ->
          Printf.eprintf "error: %s\n" msg;
          exit 1
        | Ok vars ->
          Sol_cli_terraform.kv_args vars, resolved_target.Sol_cli_config.terraform_var_file

let cloud_init ~target ~var_file ~vars ~action () =
  check_terraform ();
  let provider = provider_of_target_path target in
  let pname, infra_dir = infra_dir provider in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-apply" () in
  (* Check the target before terraform-init, same order cloud_destroy
     already uses -- a typo'd target should fail fast, not after a
     terraform init that does nothing wrong but wastes the run. *)
  let config_vars, config_var_file =
    config_vars ~strict:(action = Apply) (Some target) in
  Printf.printf "\nInitializing cloud infrastructure (%s)...\n%!" pname;

  run_terraform_init run_log infra_dir;

  let var_file = match var_file with Some _ -> var_file | None -> config_var_file in
  let vars = config_vars @ vars in
  let var_files = match var_file with None -> [] | Some f -> [normalize_var_file f] in
  match action with
  | Plan ->
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan"
         (fun () -> Sol_cli_terraform.plan ~chdir:infra_dir ~var_files ~vars));
    Printf.printf "\nDone. Re-run with 'sol cloud apply' to change cloud resources.\n%!"
  | Apply ->
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-apply"
         (fun () -> Sol_cli_terraform.apply ~chdir:infra_dir ~var_files ~vars));

    Printf.printf "\nProvisioned endpoints:\n%!";
    print_outputs infra_dir;
    Printf.printf "\nDone.\n%!"

let cloud_destroy ~target ~var_file ~vars ~action () =
  check_terraform ();
  let provider = provider_of_target_path target in
  let pname, infra_dir = infra_dir provider in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-destroy" () in
  let config_vars, config_var_file =
    config_vars ~strict:(action = Apply) (Some target) in
  let var_file = match var_file with Some _ -> var_file | None -> config_var_file in
  let vars = config_vars @ vars in
  let var_files = match var_file with None -> [] | Some f -> [normalize_var_file f] in

  Printf.printf "\nDestroying cloud infrastructure (%s)...\n%!" pname;

  run_terraform_init run_log infra_dir;

  match action with
  | Plan ->
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan-destroy"
         (fun () -> Sol_cli_terraform.plan_destroy ~chdir:infra_dir ~var_files ~vars));
    Printf.printf "\nDone. Re-run with --apply to destroy cloud resources.\n%!"
  | Apply ->
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-destroy"
         (fun () -> Sol_cli_terraform.destroy ~chdir:infra_dir ~var_files ~vars));
    Printf.printf "\nVerifying teardown...\n%!";
    (match provider with
     | Aws -> verify_aws_destroy ~var_files ~vars
     | Gcp -> Printf.printf "  (GCP destroy verification not implemented yet)\n%!");
    Printf.printf "\nDone.\n%!"

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let var_file_arg =
  Arg.(value & opt (some string) None &
       info ["var-file"] ~docv:"PATH"
         ~doc:"Path to a Terraform .tfvars file. Passed as -var-file to \
               terraform.")

let target_arg =
  Arg.(required & pos 0 (some string) None &
       info [] ~docv:"TARGET"
         ~doc:"Deployment target path: <env>/<provider>/<region>.")

let var_arg =
  Arg.(value & opt_all string [] &
       info ["var"] ~docv:"KEY=VALUE"
         ~doc:"Terraform variable. Can be passed multiple times.")

let plan_flag =
  Arg.(value & flag &
       info ["plan"]
         ~doc:"Run terraform plan only. No infrastructure is changed. This is the default.")

let apply_flag =
  Arg.(value & flag &
       info ["apply"]
         ~doc:"Run terraform apply/destroy and change billable cloud resources.")

let action_term =
  Term.(ret (const action_of_flags $ plan_flag $ apply_flag))

let plan_cmd =
  Cmd.v
    (Cmd.info "plan"
       ~doc:"Preview cloud infrastructure changes for a target.")
    Term.(const (fun target var_file vars ->
        cloud_init ~target ~var_file ~vars ~action:Plan ())
      $ target_arg $ var_file_arg $ var_arg)

let apply_cmd =
  Cmd.v
    (Cmd.info "apply"
       ~doc:"Apply cloud infrastructure changes for a target.")
    Term.(const (fun target var_file vars ->
        cloud_init ~target ~var_file ~vars ~action:Apply ())
      $ target_arg $ var_file_arg $ var_arg)

let destroy_cmd =
  Cmd.v
    (Cmd.info "destroy"
       ~doc:"Destroy cloud infrastructure via Terraform. \
             Requires the same target/provider used with apply.")
    Term.(const (fun target var_file vars action ->
        cloud_destroy ~target ~var_file ~vars ~action ())
      $ target_arg $ var_file_arg $ var_arg $ action_term)
