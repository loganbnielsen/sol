(* sol cloud plan/apply/destroy — manage cloud infrastructure via Terraform.
   Requires: terraform binary in PATH, cloud credentials in environment. *)

open Cmdliner

(* ── Sol home resolution ─────────────────────────────────────────────────── *)

(* Resolve the Sol monorepo root so we can locate cli/platform/infra/<provider>/. *)
let resolve_sol_home () =
  match Sol_cli_cmd_new.infer_sol_home () with
  | Some dir -> dir
  | None ->
    Printf.eprintf "error: cannot locate the Sol monorepo root.\n";
    Printf.eprintf "  Set SOL_HOME to your Sol checkout and re-run:\n";
    Printf.eprintf "    export SOL_HOME=/path/to/sol\n";
    exit 1
;;

(* ── Terraform output parsing ───────────────────────────────────────────── *)

(* Read terraform output -json from a temp file and print key endpoints.
   We only print non-sensitive string/list values. *)
let print_outputs infra_dir =
  match Sol_cli_terraform.output_json ~chdir:infra_dir () with
  | Error _ | Ok { Sol_cli_process.exit_code = 1 | 2 | 127 | 128; _ } ->
    Printf.printf "  (could not retrieve terraform outputs)\n%!"
  | Ok r when r.Sol_cli_process.exit_code <> 0 ->
    Printf.printf "  (could not retrieve terraform outputs)\n%!"
  | Ok r ->
    (try
       let print_output_field key obj =
         match obj with
         | `Assoc fields ->
           let sensitive =
             match List.assoc_opt "sensitive" fields with
             | Some (`Bool b) -> b
             | _ -> true
           in
           if not sensitive
           then (
             match List.assoc_opt "value" fields with
             | Some (`String v) -> Printf.printf "  %-28s  %s\n%!" key v
             | Some (`List vs) ->
               let strs =
                 List.filter_map
                   (function
                     | `String s -> Some s
                     | _ -> None)
                   vs
               in
               if strs <> []
               then Printf.printf "  %-28s  [%s]\n%!" key (String.concat ", " strs)
             | Some `Null -> Printf.printf "  %-28s  (none)\n%!" key
             | _ -> ())
         | _ -> ()
       in
       let json = Yojson.Safe.from_string r.Sol_cli_process.stdout in
       match json with
       | `Assoc pairs -> List.iter (fun (key, obj) -> print_output_field key obj) pairs
       | _ -> ()
     with
     | _ -> Printf.printf "  (error parsing terraform outputs)\n%!")
;;

let contains ~needle s =
  let nlen = String.length needle in
  let slen = String.length s in
  let rec loop i = i + nlen <= slen && (String.sub s i nlen = needle || loop (i + 1)) in
  nlen = 0 || loop 0
;;

(* ── cloud apply/plan ───────────────────────────────────────────────────── *)

let provider_of_target_path target =
  match String.split_on_char '/' target with
  | [ _env; provider; _region ] ->
    (match Sol_cli_provider.of_string provider with
     | Some provider -> provider
     | None ->
       Printf.eprintf "error: unsupported provider %S in target %S.\n" provider target;
       exit 1)
  | _ ->
    Printf.eprintf "error: target must look like <env>/<provider>/<region>.\n";
    exit 1
;;

let check_terraform () =
  if not (Sol_cli_terraform.which_check ())
  then (
    Printf.eprintf "error: %S not found in PATH.\n" "terraform";
    Printf.eprintf "  Install: %s\n" "https://developer.hashicorp.com/terraform/install";
    exit 1)
;;

let infra_dir provider =
  let pname = Sol_cli_provider.to_string provider in
  let sol_home = resolve_sol_home () in
  let dir = Filename.concat sol_home (Printf.sprintf "cli/platform/infra/%s" pname) in
  if not (Sys.file_exists dir)
  then (
    Printf.eprintf "error: Terraform module not found: %s\n" dir;
    exit 1);
  pname, dir
;;

let platform_dir () = Filename.concat (resolve_sol_home ()) "cli/platform/infra/base"

type action =
  | Plan
  | Apply

let action_of_flags plan apply =
  match plan, apply with
  | true, false -> `Ok Plan
  | false, true -> `Ok Apply
  | false, false -> `Ok Plan
  | true, true -> `Error (false, "--plan and --apply are mutually exclusive")
;;

let exit_code_of r =
  match r with
  | Ok r -> r.Sol_cli_process.exit_code
  | Error _ -> 1
;;

(* Full stdout/stderr already went to this run's phase log via
   Sol_cli_run_log.run_phase, which also printed the compact status line and,
   on failure, the log path and its tail. Nothing left to print here. *)
let require_terraform_success r =
  match r with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> ()
  | _ -> exit 1
;;

let normalize_var_file path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
;;

let trim_quotes s =
  let s = String.trim s in
  let len = String.length s in
  if len >= 2 && s.[0] = '"' && s.[len - 1] = '"' then String.sub s 1 (len - 2) else s
;;

let var_value key vars =
  List.find_map
    (fun v ->
       match String.index_opt v '=' with
       | None -> None
       | Some i ->
         if String.sub v 0 i |> String.trim = key
         then Some (String.sub v (i + 1) (String.length v - i - 1) |> trim_quotes)
         else None)
    (List.rev vars)
;;

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
             if line = "" || line.[0] = '#'
             then loop ()
             else (
               match String.index_opt line '=' with
               | None -> loop ()
               | Some i ->
                 if String.sub line 0 i |> String.trim = key
                 then
                   Some
                     (String.sub line (i + 1) (String.length line - i - 1) |> trim_quotes)
                 else loop ())
           | exception End_of_file -> None
         in
         loop ())
  with
  | _ -> None
;;

let resolved_var key ~var_files ~vars ~default =
  match var_value key vars with
  | Some _ as v -> v
  | None ->
    (match List.find_map (var_file_value key) var_files with
     | Some _ as v -> v
     | None -> default)
;;

let aws_absent ~region ~kind ~missing_marker ~argv =
  match
    Sol_cli_process.run (Sol_cli_process.cmd (("aws" :: argv) @ [ "--region"; region ]))
  with
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
;;

(* DEC-024: the workspace name comes from the resolved root, so it is the same
   from any descendant directory. *)
let workspace_name = Sol_cli_workspace.current_name

let aws_no_ecr_repositories ~region ~workspace_name =
  let prefix = workspace_name ^ "/" in
  let query =
    Printf.sprintf
      "repositories[?starts_with(repositoryName, `%s`)].repositoryName"
      prefix
  in
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "aws"
         ; "ecr"
         ; "describe-repositories"
         ; "--query"
         ; query
         ; "--output"
         ; "text"
         ; "--region"
         ; region
         ])
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 && String.trim r.Sol_cli_process.stdout = ""
    -> true
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    Printf.eprintf
      "error: AWS ECR repositories still exist after destroy: %s\n"
      r.Sol_cli_process.stdout;
    false
  | Ok r ->
    Printf.eprintf "error: AWS ECR verification failed: %s\n" r.Sol_cli_process.stderr;
    false
  | Error _ ->
    Printf.eprintf "error: AWS ECR verification failed: aws CLI unavailable.\n";
    false
;;

(* Works for both Classic ELB and ALB/NLB uniformly: the in-cluster AWS
   cloud-controller tags every load balancer it creates for a Service with
   kubernetes.io/cluster/<cluster-name>, regardless of LB type. Only
   covers that in-tree tagging convention -- a load balancer created by
   the standalone AWS Load Balancer Controller instead tags primarily with
   elbv2.k8s.aws/cluster, which this does not check. Not a gap today
   (cli/platform/infra/base/main.tf only installs ingress-nginx, which uses
   the in-tree cloud-controller path), but would need extending if Sol
   ever supports the standalone LBC.

   Returns None (not a bool) on a query failure so callers can tell "no
   load balancers" apart from "couldn't check" -- the two calling sites
   below need to react differently to each. *)
let load_balancers_gone ~region ~cluster_name =
  let tag_key = Printf.sprintf "kubernetes.io/cluster/%s" cluster_name in
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "aws"
         ; "resourcegroupstaggingapi"
         ; "get-resources"
         ; "--resource-type-filters"
         ; "elasticloadbalancing"
         ; "--tag-filters"
         ; Printf.sprintf "Key=%s" tag_key
         ; "--query"
         ; "ResourceTagMappingList[].ResourceARN"
         ; "--output"
         ; "text"
         ; "--region"
         ; region
         ])
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    Some (String.trim r.Sol_cli_process.stdout = "")
  | _ -> None
;;

let aws_no_load_balancers ~region ~cluster_name =
  match load_balancers_gone ~region ~cluster_name with
  | Some true -> true
  | Some false ->
    Printf.eprintf
      "error: AWS load balancer(s) still exist after destroy (tag \
       kubernetes.io/cluster/%s).\n"
      cluster_name;
    false
  | None ->
    Printf.eprintf
      "error: AWS load balancer verification failed: aws CLI unavailable or errored.\n";
    false
;;

(* The platform destroy removes the ingress Service through the named
   provisioner. AWS deprovisions its load balancer asynchronously, so wait
   before Terraform removes the VPC. The final absence check remains the hard
   gate if this best-effort wait times out. *)
let rec wait_for_load_balancers_gone ~region ~cluster_name attempts =
  if attempts = 0
  then
    Printf.printf
      "  (warning: load balancer(s) may still be deprovisioning; proceeding to cloud \
       destroy and retaining the final absence check)\n\
       %!"
  else (
    match load_balancers_gone ~region ~cluster_name with
    | Some true -> ()
    | Some false | None ->
      Unix.sleepf 5.;
      wait_for_load_balancers_gone ~region ~cluster_name (attempts - 1))
;;

let verify_aws_destroy ~var_files ~vars =
  match resolved_var "cluster_name" ~var_files ~vars ~default:None with
  | None ->
    Printf.eprintf "error: cannot verify AWS destroy without cluster_name.\n";
    Printf.eprintf "  Pass the same --var cluster_name=... or --var-file used for init.\n";
    exit 1
  | Some cluster_name ->
    let region =
      Option.value
        (resolved_var "region" ~var_files ~vars ~default:(Some "us-east-1"))
        ~default:"us-east-1"
    in
    let eks_gone =
      aws_absent
        ~region
        ~kind:"EKS cluster"
        ~missing_marker:"ResourceNotFoundException"
        ~argv:[ "eks"; "describe-cluster"; "--name"; cluster_name ]
    in
    let rds_gone =
      aws_absent
        ~region
        ~kind:"RDS instance"
        ~missing_marker:"DBInstanceNotFound"
        ~argv:
          [ "rds"
          ; "describe-db-instances"
          ; "--db-instance-identifier"
          ; cluster_name ^ "-postgres"
          ]
    in
    let workspace_name =
      Option.value
        (resolved_var "workspace_name" ~var_files ~vars ~default:None)
        ~default:(workspace_name ())
    in
    let ecr_gone = aws_no_ecr_repositories ~region ~workspace_name in
    let elb_gone = aws_no_load_balancers ~region ~cluster_name in
    if not (eks_gone && rds_gone && ecr_gone && elb_gone) then exit 1;
    Printf.printf "  AWS verification passed: EKS/RDS/ECR/load-balancers not found.\n%!"
;;

let terraform_init run_log infra_dir backend_config =
  Sol_cli_run_log.run_phase run_log ~name:"terraform-init" (fun () ->
    Sol_cli_terraform.init ~chdir:infra_dir ~backend_config ())
;;

let run_terraform_init run_log infra_dir backend_config =
  require_terraform_success (terraform_init run_log infra_dir backend_config)
;;

let lifecycle_error message =
  Printf.eprintf "error: %s\n%!" message;
  exit 1
;;

let established_target = function
  | Some target -> target
  | None -> lifecycle_error "cloud lifecycle requires a resolved target"
;;

let aws_outputs infra_dir =
  match Sol_cli_terraform.output_json ~chdir:infra_dir () with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    (match Yojson.Safe.from_string result.stdout with
     | `Assoc [] -> Ok None
     | _ ->
       Result.map
         (fun outputs -> Some outputs)
         (Sol_cli_cloud_lifecycle.aws_outputs_of_json result.stdout)
     | exception Yojson.Json_error message ->
       Error ("invalid AWS Terraform output JSON: " ^ message))
  | Ok result ->
    Error (Printf.sprintf "terraform output failed with exit %d" result.exit_code)
  | Error _ -> Error "could not read AWS Terraform outputs"
;;

let provisioner_kubeconfig ~region outputs f =
  let path = Filename.temp_file "sol-platform-provisioner-" ".kubeconfig" in
  let cleanup () =
    try Sys.remove path with
    | Sys_error _ -> ()
  in
  (* Phase failures terminate through [lifecycle_error] -> [exit], which does not
     unwind the stack, so [Fun.protect]'s finalizer alone would leak this
     privileged kubeconfig on every injected failure. Register the same cleanup
     with [at_exit] as well; it is idempotent. *)
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
    let env = [ "KUBECONFIG", path ] in
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           ~env
           [ "aws"
           ; "eks"
           ; "update-kubeconfig"
           ; "--region"
           ; region
           ; "--name"
           ; Sol_cli_cloud_lifecycle.cluster_name outputs
           ; "--alias"
           ; Sol_cli_cloud_lifecycle.cluster_name outputs
           ; "--role-arn"
           ; Sol_cli_cloud_lifecycle.provisioner_role_arn outputs
           ; "--kubeconfig"
           ; path
           ])
    with
    | Ok result when result.exit_code = 0 -> Ok (f env)
    | _ -> Error "could not establish ephemeral provisioner cluster access")
;;

let with_provisioner_kubeconfig ?(on_error = Fun.id) ~region outputs f =
  match provisioner_kubeconfig ~region outputs f with
  | Ok value -> value
  | Error message ->
    on_error ();
    lifecycle_error message
;;

let process_ok ?(env = []) argv =
  match Sol_cli_process.run (Sol_cli_process.cmd ~env argv) with
  | Ok result -> result.exit_code = 0
  | Error _ -> false
;;

let process_output ?(env = []) argv =
  match Sol_cli_process.run (Sol_cli_process.cmd ~env argv) with
  | Ok result when result.exit_code = 0 -> Some result.stdout
  | _ -> None
;;

let aws_cloud_ready ~region outputs =
  let cluster = Sol_cli_cloud_lifecycle.cluster_name outputs in
  let status args = process_output ([ "aws" ] @ args @ [ "--region"; region ]) in
  match
    ( status
        [ "eks"
        ; "describe-cluster"
        ; "--name"
        ; cluster
        ; "--query"
        ; "cluster.status"
        ; "--output"
        ; "text"
        ]
    , status
        [ "eks"
        ; "describe-addon"
        ; "--cluster-name"
        ; cluster
        ; "--addon-name"
        ; "aws-ebs-csi-driver"
        ; "--query"
        ; "addon.status"
        ; "--output"
        ; "text"
        ] )
  with
  | Some cluster_status, Some addon_status
    when String.trim cluster_status = "ACTIVE" && String.trim addon_status = "ACTIVE" ->
    true
  | _ -> false
;;

let crds_established env =
  process_ok
    ~env
    [ "kubectl"
    ; "wait"
    ; "--for=condition=Established"
    ; "crd/certificates.cert-manager.io"
    ; "crd/clusterissuers.cert-manager.io"
    ; "--timeout=5s"
    ]
;;

let provisioner_rbac_established env =
  Sol_cli_cloud_lifecycle.provisioner_authorization_established ~can_i:(fun args ->
    process_ok ~env ([ "kubectl"; "auth"; "can-i" ] @ args))
;;

let platform_prerequisite_targets =
  Sol_cli_terraform.targets
    "kubernetes_namespace.cert_manager"
    [ "kubernetes_namespace.ingress_nginx"
    ; "kubernetes_namespace.argocd"
    ; "kubernetes_namespace.redpanda"
    ; "kubernetes_namespace.monitoring"
    ; "kubernetes_cluster_role.platform_provisioner_namespaced"
    ; "kubernetes_role_binding.platform_provisioner"
    ; "kubernetes_cluster_role.platform_provisioner_cluster"
    ; "kubernetes_cluster_role_binding.platform_provisioner_cluster"
    ; "helm_release.cert_manager"
    ]
;;

let rds_target = Sol_cli_terraform.targets "aws_db_instance.postgres" []

let unique_rds_snapshot_id cluster_name =
  (* Millisecond resolution: a `.0f` second timestamp could collide if a
     destroy were retried within the same second. AWS snapshot identifiers
     disallow `.`, hence the truncated int rather than a raw float. *)
  Printf.sprintf
    "%s-postgres-final-%d"
    cluster_name
    (int_of_float (Unix.gettimeofday () *. 1000.))
;;

(* This root's own applied state, not the named cross-root output contract in
   Sol_cli_cloud_lifecycle -- that contract exists for wiring the platform
   root, not for a root checking its own resource against itself. [Ok None]
   means the instance does not exist (create_rds = false), which is
   trivially prepared for destruction. *)
let rds_state infra_dir =
  match Sol_cli_terraform.show_json ~chdir:infra_dir () with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    (try
       let open Yojson.Safe.Util in
       let resource =
         Yojson.Safe.from_string result.stdout
         |> member "values"
         |> member "root_module"
         |> member "resources"
         |> to_list
         |> List.find_opt (fun r -> member "type" r = `String "aws_db_instance")
       in
       match resource with
       | None -> Ok None
       | Some r ->
         let v = member "values" r in
         let deletion_protection = v |> member "deletion_protection" |> to_bool in
         let final_snapshot_identifier =
           match v |> member "final_snapshot_identifier" with
           | `String s -> Some s
           | _ -> None
         in
         Ok (Some (deletion_protection, final_snapshot_identifier))
     with
     | Yojson.Json_error message -> Error ("invalid `terraform show -json`: " ^ message)
     | Yojson.Safe.Util.Type_error (message, _) ->
       Error ("unexpected `terraform show -json` shape: " ^ message))
  | Ok result ->
    Error (Printf.sprintf "terraform show failed with exit %d" result.exit_code)
  | Error _ -> Error "could not read terraform state"
;;

(* ADR 0002 / HARDEN-002 finding 9b: lifting RDS deletion protection is a
   state transition (ModifyDBInstance), and a destroy plan contains only
   deletes -- a `-var` passed to `terraform destroy` never reaches the
   provider, which is handed prior state (see the now-resolved comment this
   replaced). Preparation is therefore its own targeted apply against just
   the RDS resource, with a snapshot identity unique to this destroy attempt
   so re-running destroy after a fresh apply can never collide with a prior
   attempt's final snapshot. *)
let prepare_destroy run_log infra_dir var_files vars ~cluster_name =
  match rds_state infra_dir with
  | Error message -> lifecycle_error message
  | Ok None ->
    Printf.printf "  prepare: no RDS instance for this target, nothing to prepare.\n%!";
    None
  | Ok (Some _) ->
    let snapshot_id = unique_rds_snapshot_id cluster_name in
    Printf.printf
      "  prepare: disabling RDS deletion protection, final snapshot %s...\n%!"
      snapshot_id;
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"rds-destroy-prepare" (fun () ->
         Sol_cli_terraform.apply
           ~scope:rds_target
           ~chdir:infra_dir
           ~var_files
           ~vars:
             (vars
              @ [ "rds_deletion_protection=false"
                ; "rds_skip_final_snapshot=false"
                ; "rds_final_snapshot_identifier=" ^ snapshot_id
                ])
           ()));
    Some snapshot_id
;;

let verify_destroy_preparation infra_dir ~prepared =
  match prepared with
  | None -> Printf.printf "  verify preparation: nothing was prepared.\n%!"
  | Some snapshot_id ->
    (match rds_state infra_dir with
     | Error message -> lifecycle_error message
     | Ok None ->
       lifecycle_error
         "RDS destroy preparation ran but the instance is now absent from state"
     | Ok (Some (deletion_protection, final_snapshot_identifier)) ->
       if deletion_protection
       then lifecycle_error "RDS deletion protection is still enabled after preparation";
       if final_snapshot_identifier <> Some snapshot_id
       then
         lifecycle_error
           (Printf.sprintf
              "RDS final snapshot identifier is %s, expected the prepared %s"
              (Option.value final_snapshot_identifier ~default:"<none>")
              snapshot_id);
       Printf.printf
         "  verify preparation: RDS deletion protection disabled, final snapshot %s \
          confirmed.\n\
          %!"
         snapshot_id)
;;

let platform_absent env =
  [ "cert-manager"; "ingress-nginx"; "argocd"; "redpanda"; "monitoring"; "postgresql" ]
  |> List.for_all (fun namespace ->
    not (process_ok ~env [ "kubectl"; "get"; "namespace"; namespace ]))
;;

let config_vars ~strict target =
  match target with
  | None -> [], None, None
  | Some target_path ->
    (match Sol_cli_config.load_for_target ~target:target_path with
     | Error e ->
       Printf.eprintf "error: %s\n" (Sol_cli_config.error_to_string e);
       exit 1
     | Ok cfg ->
       (match Sol_cli_config.target cfg with
        | None ->
          Printf.eprintf "error: target %S not found\n" target_path;
          exit 1
        | Some resolved_target ->
          (* Only Apply/destroy mutate real infrastructure; Plan and
           plan-destroy are previews, matching sol plan's own permissive
           contract. Same reasoning as cmd_deploy.ml's check: a typo'd or
           unintended target must not silently inherit sol.yml's shared
           defaults and terraform apply/destroy anyway. *)
          if strict && not (Sys.file_exists (Sol_cli_config.target_file resolved_target))
          then (
            Printf.eprintf
              "error: no %s for target %S -- terraform apply/destroy require an explicit \
               target file, even an empty one, so a typo'd or unintended target can't \
               silently inherit sol.yml's shared defaults and mutate infrastructure \
               anyway.\n"
              (Sol_cli_config.target_file resolved_target)
              target_path;
            exit 1);
          (match Sol_cli_config.terraform_vars ~workspace:(workspace_name ()) cfg with
           | Error msg ->
             Printf.eprintf "error: %s\n" msg;
             exit 1
           | Ok vars ->
             ( Sol_cli_terraform.kv_args vars
             , resolved_target.Sol_cli_config.terraform_var_file
             , Some resolved_target ))))
;;

let cloud_init ~target ~var_file ~vars ~action () =
  check_terraform ();
  let provider = provider_of_target_path target in
  if provider <> Sol_cli_provider.Aws
  then lifecycle_error "the complete cloud lifecycle is currently qualified only for AWS";
  let pname, infra_dir = infra_dir provider in
  let platform_dir = platform_dir () in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-apply" () in
  (* Check the target before terraform-init, same order cloud_destroy
     already uses -- a typo'd target should fail fast, not after a
     terraform init that does nothing wrong but wastes the run. *)
  let config_vars, config_var_file, target_cfg =
    config_vars ~strict:(action = Apply) (Some target)
  in
  let var_file =
    match var_file with
    | Some _ -> var_file
    | None -> config_var_file
  in
  let vars =
    Sol_cli_config.vars_with_profile_precedence
      ~has_profile:
        (match target_cfg with
         | Some { Sol_cli_config.profile = Some _; _ } -> true
         | _ -> false)
      ~cli_vars:vars
      ~config_vars
  in
  let target_cfg = established_target target_cfg in
  let aws_target =
    match Sol_cli_cloud_lifecycle.aws_target target_cfg with
    | Ok target -> target
    | Error message -> lifecycle_error message
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target aws_target in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend aws_target in
  let platform_backend = Sol_cli_cloud_lifecycle.platform_backend aws_target in
  let var_files =
    match var_file with
    | None -> []
    | Some f -> [ normalize_var_file f ]
  in
  (* HARDEN-002 (run 1): refuse an unusable database credential before terraform
     runs at all -- not merely before it mutates AWS. An argv-supplied password is
     refused too, because the run log records the terraform command line. *)
  (match
     Sol_cli_db_credential.check
       ~provider
       ~vars
       ~tf_var_env:(Sys.getenv_opt "TF_VAR_db_password")
   with
   | Ok () -> ()
   | Error msg ->
     Printf.eprintf "\nerror: %s\n%!" msg;
     exit 1);
  Printf.printf "\nInitializing cloud infrastructure (%s)...\n%!" pname;
  run_terraform_init run_log infra_dir cloud_backend;
  match action with
  | Plan ->
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan" (fun () ->
         Sol_cli_terraform.plan
           ~scope:Sol_cli_terraform.whole_root
           ~chdir:infra_dir
           ~var_files
           ~vars
           ()));
    let report_phase name = function
      | Sol_cli_cloud_lifecycle.Plannable -> Printf.printf "\n%s\n  PLANNED\n%!" name
      | Sol_cli_cloud_lifecycle.Deferred reason ->
        Printf.printf "\n%s\n  DEFERRED — %s\n%!" name reason
    in
    (match aws_outputs infra_dir with
     | Ok None ->
       report_phase
         "Platform prerequisites"
         (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist");
       report_phase
         "Platform substrate"
         (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist")
     | Error message -> lifecycle_error message
     | Ok (Some outputs) ->
       let platform_vars =
         match Sol_cli_cloud_lifecycle.platform_inputs aws_target outputs with
         | Ok inputs -> Sol_cli_cloud_lifecycle.platform_terraform_vars inputs
         | Error message -> lifecycle_error message
       in
       (* An unavailable cluster credential is not a deferred phase: it is an
          unavailable lifecycle prerequisite, so plan exits non-zero. Deferral is
          reserved for phases whose concrete prerequisite is simply not
          established yet and whose establishment would itself be a mutation. *)
       with_provisioner_kubeconfig ~region:target_cfg.region outputs (fun env ->
         (* [can-i --list] needs authentication only, so it succeeds with an empty
            rule set when the provisioner's RBAC is simply not established yet, and
            fails when the cluster credential is unavailable. Deferral is honest
            only in the former case: the plan exit-status contract makes an
            unavailable credential a non-zero result, not a deferred phase. The
            default [can-i] checks cannot tell the two apart -- both return 1. *)
         if not (process_ok ~env [ "kubectl"; "auth"; "can-i"; "--list" ])
         then
           lifecycle_error
             "could not authenticate to the cluster as the platform provisioner; \
              refusing to report an unavailable cluster credential as a deferred phase";
         let rbac_established = provisioner_rbac_established env in
         let crds_established = rbac_established && crds_established env in
         let prerequisites, substrate =
           Sol_cli_cloud_lifecycle.platform_plan_phases
             ~cluster_exists:true
             ~rbac_established
             ~crds_established
         in
         (match prerequisites with
          | Sol_cli_cloud_lifecycle.Plannable ->
            run_terraform_init run_log platform_dir platform_backend;
            require_terraform_success
              (Sol_cli_run_log.run_phase
                 run_log
                 ~name:"platform-prerequisites-plan"
                 (fun () ->
                    Sol_cli_terraform.plan
                      ~env
                      ~scope:platform_prerequisite_targets
                      ~chdir:platform_dir
                      ~var_files:[]
                      ~vars:platform_vars
                      ()))
          | Sol_cli_cloud_lifecycle.Deferred _ -> ());
         (match substrate with
          | Sol_cli_cloud_lifecycle.Plannable ->
            require_terraform_success
              (Sol_cli_run_log.run_phase run_log ~name:"platform-plan" (fun () ->
                 Sol_cli_terraform.plan
                   ~env
                   ~scope:Sol_cli_terraform.whole_root
                   ~chdir:platform_dir
                   ~var_files:[]
                   ~vars:platform_vars
                   ()))
          | Sol_cli_cloud_lifecycle.Deferred _ -> ());
         report_phase "Platform prerequisites" prerequisites;
         report_phase "Platform substrate" substrate));
    Printf.printf "\nDone. Re-run with 'sol cloud apply' to change cloud resources.\n%!"
  | Apply ->
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-apply" (fun () ->
         Sol_cli_terraform.apply
           ~scope:Sol_cli_terraform.whole_root
           ~chdir:infra_dir
           ~var_files
           ~vars:("provisioner_bootstrap_admin=true" :: vars)
           ()));
    let deescalate () =
      Sol_cli_run_log.run_phase
        run_log
        ~name:"provisioner-bootstrap-access-remove"
        (fun () ->
           Sol_cli_terraform.apply
             ~scope:Sol_cli_terraform.whole_root
             ~chdir:infra_dir
             ~var_files
             ~vars:("provisioner_bootstrap_admin=false" :: vars)
             ())
    in
    let cleanup_bootstrap_access () = ignore (deescalate ()) in
    let outputs =
      match aws_outputs infra_dir with
      | Ok (Some v) -> v
      | Ok None ->
        cleanup_bootstrap_access ();
        lifecycle_error "AWS Terraform apply completed without lifecycle outputs"
      | Error e ->
        cleanup_bootstrap_access ();
        lifecycle_error e
    in
    let platform_vars =
      match Sol_cli_cloud_lifecycle.platform_inputs aws_target outputs with
      | Ok inputs -> Sol_cli_cloud_lifecycle.platform_terraform_vars inputs
      | Error message ->
        cleanup_bootstrap_access ();
        lifecycle_error message
    in
    if not (aws_cloud_ready ~region:target_cfg.region outputs)
    then (
      cleanup_bootstrap_access ();
      lifecycle_error "AWS cloud substrate is not Ready (EKS cluster/EBS CSI addon)");
    with_provisioner_kubeconfig
      ~on_error:cleanup_bootstrap_access
      ~region:target_cfg.region
      outputs
      (fun env ->
         let platform_init = terraform_init run_log platform_dir platform_backend in
         (match platform_init with
          | Ok result when result.exit_code = 0 -> ()
          | _ ->
            cleanup_bootstrap_access ();
            require_terraform_success platform_init);
         let prerequisites =
           Sol_cli_run_log.run_phase
             run_log
             ~name:"platform-prerequisites-apply"
             (fun () ->
                Sol_cli_terraform.apply
                  ~env
                  ~scope:platform_prerequisite_targets
                  ~chdir:platform_dir
                  ~var_files:[]
                  ~vars:platform_vars
                  ())
         in
         (match prerequisites with
          | Ok result when result.exit_code = 0 -> ()
          | _ ->
            cleanup_bootstrap_access ();
            require_terraform_success prerequisites);
         if
           not
             (process_ok
                ~env
                [ "kubectl"
                ; "wait"
                ; "--for=condition=Established"
                ; "crd/certificates.cert-manager.io"
                ; "crd/clusterissuers.cert-manager.io"
                ; "--timeout=180s"
                ])
         then (
           cleanup_bootstrap_access ();
           lifecycle_error "cert-manager CRDs did not become Established");
         require_terraform_success (deescalate ());
         if not (provisioner_rbac_established env)
         then
           lifecycle_error
             "platform provisioner RBAC is not effective after bootstrap access removal";
         require_terraform_success
           (Sol_cli_run_log.run_phase run_log ~name:"platform-apply" (fun () ->
              Sol_cli_terraform.apply
                ~env
                ~scope:Sol_cli_terraform.whole_root
                ~chdir:platform_dir
                ~var_files:[]
                ~vars:platform_vars
                ()));
         let cluster_issuer =
           Option.value target_cfg.cluster_issuer ~default:"letsencrypt-prod"
         in
         let readiness =
           Sol_cli_cloud_lifecycle.readiness
             ~cluster_issuer
             ~observability_backend:
               (Option.value target_cfg.observability_backend ~default:"local")
             ~run:(fun args -> process_output ~env ("kubectl" :: args))
         in
         let summary = Sol_cli_cloud_lifecycle.readiness_summary readiness in
         if summary <> "Ready" then lifecycle_error ("platform readiness " ^ summary));
    Printf.printf "\nProvisioned endpoints:\n%!";
    print_outputs infra_dir;
    Printf.printf "\nDone.\n%!"
;;

let cloud_destroy ~target ~var_file ~vars ~action () =
  check_terraform ();
  let provider = provider_of_target_path target in
  if provider <> Sol_cli_provider.Aws
  then lifecycle_error "the complete cloud lifecycle is currently qualified only for AWS";
  let pname, infra_dir = infra_dir provider in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-destroy" () in
  let config_vars, config_var_file, target_cfg =
    config_vars ~strict:(action = Apply) (Some target)
  in
  let var_file =
    match var_file with
    | Some _ -> var_file
    | None -> config_var_file
  in
  let vars = config_vars @ vars in
  let target_cfg = established_target target_cfg in
  let aws_target =
    match Sol_cli_cloud_lifecycle.aws_target target_cfg with
    | Ok target -> target
    | Error message -> lifecycle_error message
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target aws_target in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend aws_target in
  let var_files =
    match var_file with
    | None -> []
    | Some f -> [ normalize_var_file f ]
  in
  Printf.printf "\nDestroying cloud infrastructure (%s)...\n%!" pname;
  run_terraform_init run_log infra_dir cloud_backend;
  let outputs =
    match aws_outputs infra_dir with
    | Ok outputs -> outputs
    | Error message -> lifecycle_error message
  in
  let destroy_platform ?(on_error = Fun.id) outputs =
    let platform_dir = platform_dir () in
    let platform_backend = Sol_cli_cloud_lifecycle.platform_backend aws_target in
    let platform_vars =
      match Sol_cli_cloud_lifecycle.platform_inputs aws_target outputs with
      | Ok inputs -> Sol_cli_cloud_lifecycle.platform_terraform_vars inputs
      | Error message -> lifecycle_error message
    in
    with_provisioner_kubeconfig ~on_error ~region:target_cfg.region outputs (fun env ->
      let init = terraform_init run_log platform_dir platform_backend in
      (match init with
       | Ok result when result.exit_code = 0 -> ()
       | _ ->
         on_error ();
         require_terraform_success init);
      let destroy =
        Sol_cli_run_log.run_phase run_log ~name:"platform-destroy" (fun () ->
          Sol_cli_terraform.destroy
            ~env
            ~chdir:platform_dir
            ~var_files:[]
            ~vars:platform_vars
            ())
      in
      match destroy with
      | Ok result when result.exit_code = 0 ->
        if not (platform_absent env)
        then (
          on_error ();
          lifecycle_error "platform absence verification failed after destroy")
      | _ ->
        on_error ();
        require_terraform_success destroy)
  in
  match action with
  | Plan ->
    (match outputs with
     | None ->
       Printf.printf "  Platform destroy DEFERRED — cloud substrate is absent.\n%!"
     | Some outputs ->
       let platform_dir = platform_dir () in
       let platform_backend = Sol_cli_cloud_lifecycle.platform_backend aws_target in
       let platform_vars =
         match Sol_cli_cloud_lifecycle.platform_inputs aws_target outputs with
         | Ok inputs -> Sol_cli_cloud_lifecycle.platform_terraform_vars inputs
         | Error message -> lifecycle_error message
       in
       with_provisioner_kubeconfig ~region:target_cfg.region outputs (fun env ->
         run_terraform_init run_log platform_dir platform_backend;
         require_terraform_success
           (Sol_cli_run_log.run_phase run_log ~name:"platform-plan-destroy" (fun () ->
              Sol_cli_terraform.plan_destroy
                ~env
                ~chdir:platform_dir
                ~var_files:[]
                ~vars:platform_vars
                ()))));
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan-destroy" (fun () ->
         Sol_cli_terraform.plan_destroy ~chdir:infra_dir ~var_files ~vars ()));
    Printf.printf "\nDone. Re-run with --apply to destroy cloud resources.\n%!"
  | Apply ->
    (match outputs with
     | None ->
       Printf.printf "  prepare: cloud substrate is absent, nothing to prepare.\n%!"
     | Some outputs ->
       let cluster_name = Sol_cli_cloud_lifecycle.cluster_name outputs in
       let prepared = prepare_destroy run_log infra_dir var_files vars ~cluster_name in
       verify_destroy_preparation infra_dir ~prepared);
    (match outputs with
     | None -> ()
     | Some outputs ->
       require_terraform_success
         (Sol_cli_terraform.apply
            ~scope:Sol_cli_terraform.whole_root
            ~chdir:infra_dir
            ~var_files
            ~vars:("provisioner_bootstrap_admin=true" :: vars)
            ());
       let deescalate () =
         Sol_cli_run_log.run_phase
           run_log
           ~name:"provisioner-bootstrap-access-remove"
           (fun () ->
              Sol_cli_terraform.apply
                ~scope:Sol_cli_terraform.whole_root
                ~chdir:infra_dir
                ~var_files
                ~vars:("provisioner_bootstrap_admin=false" :: vars)
                ())
       in
       let cleanup_bootstrap_access () = ignore (deescalate ()) in
       destroy_platform ~on_error:cleanup_bootstrap_access outputs;
       require_terraform_success (deescalate ()));
    (match provider with
     | Sol_cli_provider.Aws ->
       (match resolved_var "cluster_name" ~var_files ~vars ~default:None with
        | None -> ()
        | Some cluster_name ->
          let region =
            Option.value
              (resolved_var "region" ~var_files ~vars ~default:(Some "us-east-1"))
              ~default:"us-east-1"
          in
          wait_for_load_balancers_gone ~region ~cluster_name 24)
     | Sol_cli_provider.Gcp -> ());
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-destroy" (fun () ->
         Sol_cli_terraform.destroy ~chdir:infra_dir ~var_files ~vars ()));
    Printf.printf "\nVerifying teardown...\n%!";
    (match provider with
     | Sol_cli_provider.Aws -> verify_aws_destroy ~var_files ~vars
     | Sol_cli_provider.Gcp ->
       Printf.printf "  (GCP destroy verification not implemented yet)\n%!");
    Printf.printf "\nDone.\n%!"
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let var_file_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "var-file" ]
        ~docv:"PATH"
        ~doc:"Path to a Terraform .tfvars file. Passed as -var-file to terraform.")
;;

let target_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"TARGET" ~doc:"Deployment target path: <env>/<provider>/<region>.")
;;

let var_arg =
  Arg.(
    value
    & opt_all string []
    & info
        [ "var" ]
        ~docv:"KEY=VALUE"
        ~doc:"Terraform variable. Can be passed multiple times.")
;;

let plan_flag =
  Arg.(
    value
    & flag
    & info
        [ "plan" ]
        ~doc:"Run terraform plan only. No infrastructure is changed. This is the default.")
;;

let apply_flag =
  Arg.(
    value
    & flag
    & info
        [ "apply" ]
        ~doc:"Run terraform apply/destroy and change billable cloud resources.")
;;

let action_term = Term.(ret (const action_of_flags $ plan_flag $ apply_flag))

let plan_cmd =
  Cmd.v
    (Cmd.info "plan" ~doc:"Preview cloud infrastructure changes for a target.")
    Term.(
      const (fun target var_file vars ->
        cloud_init ~target ~var_file ~vars ~action:Plan ())
      $ target_arg
      $ var_file_arg
      $ var_arg)
;;

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply cloud infrastructure changes for a target.")
    Term.(
      const (fun target var_file vars ->
        cloud_init ~target ~var_file ~vars ~action:Apply ())
      $ target_arg
      $ var_file_arg
      $ var_arg)
;;

let destroy_cmd =
  Cmd.v
    (Cmd.info
       "destroy"
       ~doc:
         "Destroy cloud infrastructure via Terraform. Requires the same target/provider \
          used with apply.")
    Term.(
      const (fun target var_file vars action ->
        cloud_destroy ~target ~var_file ~vars ~action ())
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ action_term)
;;
