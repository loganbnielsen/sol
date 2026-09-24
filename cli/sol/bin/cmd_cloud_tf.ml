(* sol cloud plan/apply/destroy — manage cloud infrastructure via Terraform.
   Requires: terraform binary in PATH, cloud credentials in environment. *)

open Cmdliner

(* The destroy execution core (Sol_cli_cloud_destroy) and the result-returning
   helpers below carry failures as values rather than exiting: only the command
   edge turns an outcome into a process exit (REFAC-091). *)
let ( let* ) = Result.bind

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

let platform_dir provider =
  Filename.concat (resolve_sol_home ()) (Sol_cli_cloud_lifecycle.platform_root provider)
;;

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
(* Live attempt 1's destruction failure was diagnosed only by reconstructing it
   by hand: this exited non-zero and printed nothing, and the failure's terraform
   output was recorded only if the call happened to sit inside a run phase. An
   operation that fails must say why -- the run log is the record, but the reason
   is not something an operator should have to go looking for. *)
let require_terraform_success r =
  match r with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> ()
  | Ok r ->
    let detail = String.trim r.Sol_cli_process.stderr in
    Printf.eprintf
      "\nterraform exited %d%s\n%!"
      r.Sol_cli_process.exit_code
      (if detail = "" then "." else ":\n" ^ detail);
    exit 1
  | Error error ->
    Printf.eprintf
      "\ncould not run terraform: %s\n%!"
      (Sol_cli_process.error_to_string error);
    exit 1
;;

(* REFAC-091: the same classification [require_terraform_success] makes, returned
   as a value rather than exiting, so the destroy execution sequence can carry a
   terraform failure in its typed outcome. *)
let terraform_outcome (r : (Sol_cli_process.result, Sol_cli_process.error) result)
  : (unit, string) result
  =
  match r with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok ()
  | Ok r ->
    let detail = String.trim r.Sol_cli_process.stderr in
    Error
      (Printf.sprintf
         "terraform exited %d%s"
         r.Sol_cli_process.exit_code
         (if detail = "" then "." else ":\n" ^ detail))
  | Error error ->
    Error
      (Printf.sprintf
         "could not run terraform: %s"
         (Sol_cli_process.error_to_string error))
;;

(* Like [terraform_outcome], but keeps the command's stdout -- [terraform show
   -json <plan>] is read, not just checked. *)
let terraform_stdout (r : (Sol_cli_process.result, Sol_cli_process.error) result)
  : (string, string) result
  =
  match r with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> Ok r.Sol_cli_process.stdout
  | Ok r ->
    let detail = String.trim r.Sol_cli_process.stderr in
    Error
      (Printf.sprintf
         "terraform exited %d%s"
         r.Sol_cli_process.exit_code
         (if detail = "" then "." else ":\n" ^ detail))
  | Error error ->
    Error
      (Printf.sprintf
         "could not run terraform: %s"
         (Sol_cli_process.error_to_string error))
;;

(* HARDEN-004 step 3: the one way a destroy-path apply runs. The exact scope and
   variables are planned first; the plan is classified against [policy]; the
   saved plan is applied only when every change is permitted. A plan that cannot
   be produced, read or classified refuses, and the apply is never invoked. The
   saved plan is removed however this returns. *)
let apply_asserted ~run_log ~phase_name ~policy ~scope ~chdir ~var_files ~vars ()
  : (unit, string) result
  =
  let plan_file = Filename.temp_file "sol-destroy-" ".tfplan" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove plan_file with
      | Sys_error _ -> ())
    (fun () ->
       match
         Sol_cli_terraform_plan.guarded_apply
           ~policy
           ~plan:(fun () ->
             match
               terraform_stdout
                 (Sol_cli_run_log.run_phase
                    run_log
                    ~name:(phase_name ^ "-plan")
                    (fun () ->
                       Sol_cli_terraform.plan_saved
                         ~scope
                         ~chdir
                         ~var_files
                         ~vars
                         ~out:plan_file
                         ()))
             with
             | Ok _ -> Ok plan_file
             | Error message -> Error message)
           ~show_plan:(fun file ->
             terraform_stdout
               (Sol_cli_run_log.run_phase run_log ~name:(phase_name ^ "-show") (fun () ->
                  Sol_cli_terraform.show_json_plan ~chdir ~plan_file:file ())))
           ~apply_plan:(fun file ->
             terraform_outcome
               (Sol_cli_run_log.run_phase run_log ~name:phase_name (fun () ->
                  Sol_cli_terraform.apply_saved ~chdir ~plan_file:file ())))
           ()
       with
       | Ok () -> Ok ()
       | Error failure -> Error (Sol_cli_terraform_plan.apply_failure_to_string failure))
;;

(* The bootstrap-access mechanism's Terraform identity, per provider.

   GCP's is a root-level resource with a stable address. AWS's is an access-policy
   association owned by the `eks` module, whose internal address is
   module-version-dependent -- naming it here by address would be a guess that
   could not be validated offline, and a wrong `-target` fails closed but strands
   the target. So the module is the smallest *stable* scope that contains it, the
   rule names the resource type, and the plan assertion is what keeps it narrow. *)
let bootstrap_matchers = function
  | Sol_cli_provider.Gcp ->
    [ Sol_cli_terraform_plan.Exact
        "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
    ]
  | Sol_cli_provider.Aws ->
    [ Sol_cli_terraform_plan.Type "aws_eks_access_policy_association" ]
;;

let bootstrap_scope = function
  | Sol_cli_provider.Gcp ->
    Sol_cli_terraform.targets
      "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
      []
  | Sol_cli_provider.Aws -> Sol_cli_terraform.targets "module.eks" []
;;

(* The reconciliation apply's scope: the bootstrap mechanism plus the guarded
   resources the inventory represents -- never the whole root, so a configured-
   but-unrepresented cluster is not even planned. *)
let reconciliation_scope provider guarded =
  match provider with
  | Sol_cli_provider.Gcp ->
    Sol_cli_terraform.targets
      "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
      guarded
  | Sol_cli_provider.Aws -> Sol_cli_terraform.targets "module.eks" guarded
;;

(* [cleanup] is best-effort: the run is already failing, so a cleanup failure cannot
   change the exit path -- but it must be reported, or the operator is left believing the
   elevated access was removed when it may not have been. *)
let report_cleanup_failure ~what cleanup =
  match cleanup () with
  | Ok r when r.Sol_cli_process.exit_code = 0 -> ()
  | Ok r ->
    Printf.eprintf
      "warning: %s failed (terraform exited %d); the elevated access may still be applied\n\
       %!"
      what
      r.Sol_cli_process.exit_code
  | Error e ->
    Printf.eprintf
      "warning: %s failed (%s); the elevated access may still be applied\n%!"
      what
      (Sol_cli_process.error_to_string e)
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

(* INFRA-047: Terraform state being empty is not an absence proof for resources
   created indirectly by the VPC module or by Kubernetes.  These queries use
   the target's stable cluster name/tags and treat an API error as a failed
   verification, never as absence. *)
let aws_no_listed_resources ~region ~kind ~argv =
  match
    Sol_cli_process.run (Sol_cli_process.cmd (("aws" :: argv) @ [ "--region"; region ]))
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 && String.trim r.Sol_cli_process.stdout = ""
    -> true
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    Printf.eprintf
      "error: AWS %s still exist after destroy: %s\n"
      kind
      r.Sol_cli_process.stdout;
    false
  | Ok r ->
    Printf.eprintf "error: AWS %s verification failed: %s\n" kind r.Sol_cli_process.stderr;
    false
  | Error _ ->
    Printf.eprintf "error: AWS %s verification failed: aws CLI unavailable.\n" kind;
    false
;;

let aws_no_elastic_ips ~region ~cluster_name =
  aws_no_listed_resources
    ~region
    ~kind:"elastic IPs"
    ~argv:
      [ "ec2"
      ; "describe-addresses"
      ; "--filters"
      ; Printf.sprintf "Name=tag:Name,Values=%s-*" cluster_name
      ; "--query"
      ; "Addresses[].AllocationId"
      ; "--output"
      ; "text"
      ]
;;

let aws_no_nat_gateways ~region ~cluster_name =
  aws_no_listed_resources
    ~region
    ~kind:"NAT gateways"
    ~argv:
      [ "ec2"
      ; "describe-nat-gateways"
      ; "--filter"
      ; Printf.sprintf "Name=tag:Name,Values=%s-*" cluster_name
      ; "--query"
      ; "NatGateways[?State != `deleted`].NatGatewayId"
      ; "--output"
      ; "text"
      ]
;;

let aws_no_ebs_volumes ~region ~cluster_name =
  aws_no_listed_resources
    ~region
    ~kind:"EBS volumes"
    ~argv:
      [ "ec2"
      ; "describe-volumes"
      ; "--filters"
      ; Printf.sprintf
          "Name=tag:kubernetes.io/cluster/%s,Values=owned,shared"
          cluster_name
      ; "--query"
      ; "Volumes[].VolumeId"
      ; "--output"
      ; "text"
      ]
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

let verify_aws_destroy ~var_files ~vars : (unit, string) result =
  match resolved_var "cluster_name" ~var_files ~vars ~default:None with
  | None ->
    Error
      "cannot verify AWS destroy without cluster_name. Pass the same --var \
       cluster_name=... or --var-file used for init."
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
    let eips_gone = aws_no_elastic_ips ~region ~cluster_name in
    let nat_gone = aws_no_nat_gateways ~region ~cluster_name in
    let ebs_gone = aws_no_ebs_volumes ~region ~cluster_name in
    if
      not
        (eks_gone && rds_gone && ecr_gone && elb_gone && eips_gone && nat_gone && ebs_gone)
    then Error "AWS absence verification failed"
    else (
      Printf.printf
        "  AWS verification passed: \
         EKS/RDS/ECR/load-balancers/EIPs/NAT-gateways/EBS-volumes not found.\n\
         %!";
      Ok ())
;;

(* The GCP counterpart. Deliberately its own list rather than a shared "enumerate
   the target's resources" abstraction: the two providers name the same resources
   differently (a name plus a region against a project plus a self-link), and a
   shared shape would have to be the union of both -- which is exactly how a
   verification quietly stops checking something. *)
(* Does this error mean the resource is absent, or that the check could not tell?
   Attempt 4 showed how easy it is to get that wrong in the direction that looks
   safest.

   The check recognised `NOT_FOUND` and `was not found`. gcloud actually answers a
   deleted GKE cluster with

     ResponseError: code=404, message=Not found: projects/.../clusters/sol-qual

   and a deleted Cloud SQL instance with `HTTPError 404: The Cloud SQL instance does
   not exist`. Neither matched, so a destroy that had removed everything was
   reported as a failed verification. Failing closed is the right instinct, but a
   check that cannot recognise absence makes [Absent] unreachable -- and [Absent] is
   the postcondition the whole lifecycle is measured against.

   So absence is recognised by the provider's own wording, in the provider's own
   case, and anything else remains a verification failure rather than an
   assumption. *)
let gcp_absence_message stderr =
  let text = String.lowercase_ascii stderr in
  List.exists
    (fun needle -> contains ~needle text)
    [ "code=404"; "httperror 404"; "not_found"; "not found"; "does not exist" ]
;;

let gcp_absent ~project ~kind ~argv =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd (("gcloud" :: argv) @ [ "--project"; project ]))
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    Printf.eprintf "error: GCP %s still exists after destroy.\n" kind;
    false
  | Ok r when gcp_absence_message r.Sol_cli_process.stderr -> true
  | Ok r ->
    Printf.eprintf
      "error: GCP %s verification failed, and the failure does not say the resource is \
       absent: %s\n"
      kind
      r.Sol_cli_process.stderr;
    false
  | Error _ ->
    Printf.eprintf "error: GCP %s verification failed: gcloud unavailable.\n" kind;
    false
;;

(* Absence is graded the same way it is on AWS: a resource that is merely stopped
   has not been torn down, and one that still bills has not been either. The VPC
   also covers its subnetwork, router and NAT, which cannot outlive it. *)
let verify_gcp_destroy ~var_files ~vars : (unit, string) result =
  let* project =
    match resolved_var "project_id" ~var_files ~vars ~default:None with
    | Some project -> Ok project
    | None ->
      Error
        "cannot verify GCP destroy without project_id. Pass the same --var \
         project_id=... or --var-file used for init."
  in
  let* cluster_name =
    match resolved_var "cluster_name" ~var_files ~vars ~default:None with
    | Some cluster_name -> Ok cluster_name
    | None ->
      Error
        "cannot verify GCP destroy without cluster_name. Pass the same --var \
         cluster_name=... or --var-file used for init."
  in
  let region =
    Option.value
      (resolved_var "region" ~var_files ~vars ~default:(Some "us-central1"))
      ~default:"us-central1"
  in
  let cluster_gone =
    gcp_absent
      ~project
      ~kind:"GKE cluster"
      ~argv:[ "container"; "clusters"; "describe"; cluster_name; "--region"; region ]
  in
  let sql_gone =
    gcp_absent
      ~project
      ~kind:"Cloud SQL instance"
      ~argv:[ "sql"; "instances"; "describe"; cluster_name ^ "-postgres" ]
  in
  let network_gone =
    gcp_absent
      ~project
      ~kind:"VPC network"
      ~argv:[ "compute"; "networks"; "describe"; cluster_name ]
  in
  let registry_gone =
    gcp_absent
      ~project
      ~kind:"Artifact Registry repository"
      ~argv:
        [ "artifacts"; "repositories"; "describe"; cluster_name; "--location"; region ]
  in
  let address_gone =
    gcp_absent
      ~project
      ~kind:"Cloud SQL peering address"
      ~argv:
        [ "compute"; "addresses"; "describe"; cluster_name ^ "-sql-peering"; "--global" ]
  in
  (* The connection itself, asked of the provider rather than inferred from the
     root's exit status. Attempt 2 is why: the root now *abandons* the peering
     (`deletion_policy = "ABANDON"`) because GCP refuses to delete it while a
     producer is registered, so terraform will report success without the API ever
     being asked to remove it -- which is exactly the case where "terraform
     succeeded" and "the resource is gone" part company.

     A network that does not exist has no peerings, so the absence of the network is
     itself evidence; what this rules out is the peering surviving some other way,
     and it is checked by listing rather than by describing, because a peering has
     no name of its own to describe. *)
  let peering_gone =
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           [ "gcloud"
           ; "services"
           ; "vpc-peerings"
           ; "list"
           ; "--network=" ^ cluster_name
           ; "--service=servicenetworking.googleapis.com"
           ; "--project"
           ; project
           ; "--format=value(peering)"
           ])
    with
    | Ok result when result.Sol_cli_process.exit_code = 0 ->
      let peerings =
        String.split_on_char '\n' result.Sol_cli_process.stdout
        |> List.map String.trim
        |> List.filter (fun p -> p <> "" && p <> "---")
      in
      if peerings = []
      then true
      else (
        Printf.eprintf
          "error: the service-networking peering survived the destroy: %s\n%!"
          (String.concat ", " peerings);
        false)
    | Ok result
      when contains ~needle:"NOT_FOUND" result.Sol_cli_process.stderr
           || contains ~needle:"was not found" result.Sol_cli_process.stderr -> true
    | Ok result ->
      Printf.eprintf
        "error: could not determine whether the service-networking peering is gone: %s\n\
         %!"
        result.Sol_cli_process.stderr;
      false
    | Error _ ->
      Printf.eprintf
        "error: could not determine whether the service-networking peering is gone: \
         gcloud unavailable.\n\
         %!";
      false
  in
  if
    not
      (cluster_gone
       && sql_gone
       && network_gone
       && registry_gone
       && address_gone
       && peering_gone)
  then Error "GCP absence verification failed"
  else (
    Printf.printf
      "  GCP verification passed: GKE/Cloud SQL/network/registry/peering-address not \
       found, and no service-networking peering remains.\n\
       %!";
    Ok ())
;;

let terraform_init run_log infra_dir backend_config =
  Sol_cli_run_log.run_phase run_log ~name:"terraform-init" (fun () ->
    Sol_cli_terraform.init ~chdir:infra_dir ~backend_config ())
;;

let run_terraform_init run_log infra_dir backend_config =
  require_terraform_success (terraform_init run_log infra_dir backend_config)
;;

(* REFAC-091: the result-returning form for the destroy sequence, which carries
   an init failure in its typed outcome rather than exiting mid-sequence. *)
let run_terraform_init_result run_log infra_dir backend_config =
  terraform_outcome (terraform_init run_log infra_dir backend_config)
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

let gcp_outputs infra_dir =
  match Sol_cli_terraform.output_json ~chdir:infra_dir () with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    (match Yojson.Safe.from_string result.stdout with
     | `Assoc [] -> Ok None
     | _ ->
       Result.map
         (fun outputs -> Some outputs)
         (Sol_cli_cloud_lifecycle.gcp_outputs_of_json result.stdout)
     | exception Yojson.Json_error message ->
       Error ("invalid GCP Terraform output JSON: " ^ message))
  | Ok result ->
    Error (Printf.sprintf "terraform output failed with exit %d" result.exit_code)
  | Error _ -> Error "could not read GCP Terraform outputs"
;;

(* The cloud root's outputs, whichever provider's root published them. Every
   consumer below either dispatches on this value or is genuinely
   provider-neutral. *)
let cloud_outputs_of provider infra_dir =
  match provider with
  | Sol_cli_provider.Aws ->
    Result.map
      (Option.map (fun outputs -> Sol_cli_cloud_lifecycle.Aws_outputs outputs))
      (aws_outputs infra_dir)
  | Sol_cli_provider.Gcp ->
    Result.map
      (Option.map (fun outputs -> Sol_cli_cloud_lifecycle.Gcp_outputs outputs))
      (gcp_outputs infra_dir)
;;

(* One place that turns a cloud root's outputs into the platform definition's
   variables, so the four lifecycle stages cannot disagree about the mapping, and
   so the day a second provider's access path lands there is one call site to
   widen rather than four. [on_error] runs before the refusal is reported, which
   is how the bootstrap-access cleanup on the apply path still happens when the
   mapping itself is what failed. *)
(* The trailing [()] is not decoration: an optional argument followed by only
   labelled ones cannot be erased, so a caller that omits [on_error] would be
   typing a partial application rather than a value. *)
let platform_vars_of
      ?(on_error = Fun.id)
      ?(context = Sol_cli_cloud_lifecycle.Install)
      ~cloud_target
      ~outputs
      ()
  =
  match Sol_cli_cloud_lifecycle.platform_inputs cloud_target outputs with
  | Error message ->
    on_error ();
    lifecycle_error message
  | Ok inputs ->
    (match Sol_cli_cloud_lifecycle.platform_terraform_vars ~context inputs with
     | Ok vars -> vars
     | Error message ->
       on_error ();
       lifecycle_error message)
;;

(* REFAC-091: the result-returning core, so the destroy sequence can carry a
   wiring refusal in its typed outcome. [platform_vars_of] is the exiting wrapper
   the install path keeps using. *)
let platform_vars_of_result
      ?(context = Sol_cli_cloud_lifecycle.Install)
      ~cloud_target
      ~outputs
      ()
  : (string list, string) result
  =
  let* inputs = Sol_cli_cloud_lifecycle.platform_inputs cloud_target outputs in
  Sol_cli_cloud_lifecycle.platform_terraform_vars ~context inputs
;;

let provisioner_kubeconfig ?role_arn ~region outputs f =
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
    Printf.printf
      "  cluster access identity: %s\n%!"
      (Sol_cli_cloud_lifecycle.cluster_access_role_arn outputs);
    (* Finding 12: the base providers resolve the kubeconfig from
       KUBE_CONFIG_PATH/KUBE_CONFIG_PATHS, not KUBECONFIG. *)
    let env = Sol_cli_cloud_lifecycle.provisioner_kube_env path in
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
           ; Sol_cli_cloud_lifecycle.cluster_name
               (Sol_cli_cloud_lifecycle.Aws_outputs outputs)
           ; "--alias"
           ; Sol_cli_cloud_lifecycle.cluster_name
               (Sol_cli_cloud_lifecycle.Aws_outputs outputs)
           ; "--role-arn"
           ; (match role_arn with
              | Some arn -> arn
              | None -> Sol_cli_cloud_lifecycle.cluster_access_role_arn outputs)
           ; "--kubeconfig"
           ; path
           ])
    with
    | Ok result when result.exit_code = 0 -> Ok (f env)
    | _ -> Error "could not establish ephemeral provisioner cluster access")
;;

let with_provisioner_kubeconfig ?(on_error = Fun.id) ?role_arn ~region outputs f =
  match provisioner_kubeconfig ?role_arn ~region outputs f with
  | Ok value -> value
  | Error message ->
    on_error ();
    lifecycle_error message
;;

(* DEC-040 / FND-0021: de-escalation is not complete because a control plane said so.

   Live, an EKS access-policy disassociation was accepted, `describe-access-entry`
   reported no access policies, and the authorizer went on granting cluster-admin for
   over five minutes.

   Two things make this evidence rather than ceremony. The probe runs as **the principal
   whose bootstrap elevation this phase removes** -- the provisioner, not the
   steady-state cluster-access identity, whose refusals would say nothing about the
   provisioner's authority. And it establishes *which* principal answered before
   believing any answer: a probe that quietly authenticated as somebody else would
   "prove" exactly the thing FND-0021 showed can be false. *)
let bootstrap_only_capabilities =
  List.map
    (fun (verb, resource) -> { Sol_cli_cloud_lifecycle.verb; resource })
    [ "create", "clusterroles"
    ; "create", "clusterrolebindings"
    ; "escalate", "clusterroles"
    ]
;;

(* Run `kubectl auth can-i` and classify its result. The classification itself is a lib
   function so it can be unit tested; this only performs the call. *)
let capability_answer_of_can_i ~env { Sol_cli_cloud_lifecycle.verb; resource } =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "can-i"; verb; resource ])
  with
  | Ok r ->
    Sol_cli_cloud_lifecycle.capability_answer_of_can_i_output
      ~exit_code:r.Sol_cli_process.exit_code
      ~stdout:r.Sol_cli_process.stdout
      ~stderr:r.Sol_cli_process.stderr
  | Error e -> Sol_cli_cloud_lifecycle.Indeterminate (Sol_cli_process.error_to_string e)
;;

(* One definition of the retry interval, so the shape gate, the bootstrap-window
   control and the post-de-escalation loop cannot drift apart. Production uses the
   default; a harness overrides it to exercise the retry without sleeping through it.
   A negative or non-finite override is ignored rather than slept on -- a NaN reaches
   [Unix.sleepf] as an exception, and a negative would spend the whole retry budget in
   one pass. *)
let whoami_retry_interval_s () =
  match Sys.getenv_opt "SOL_WHOAMI_RETRY_INTERVAL_S" with
  | None -> 10.
  | Some raw ->
    (match float_of_string_opt raw with
     | Some seconds when Float.is_finite seconds && seconds >= 0. -> seconds
     | _ -> 10.)
;;

(* Bounds for the retry loops, named so they cannot drift apart silently. The shape
   gate and the window control both wait out a fresh endpoint's propagation; the
   post-removal await is longer, because FND-0021 saw an access-policy disassociation
   take over five minutes to propagate while a deletion took under 45 s. *)
let cluster_propagation_attempts = 10
let deescalation_attempts = 18

(* A refusal from the cluster, as opposed to a failure to reach it. Shared because the
   de-escalation probe treats it as evidence of de-escalation while the shape gate treats it
   as a reason to stop immediately: retrying cannot change an identity. *)
let cluster_refused detail =
  List.exists
    (fun needle -> Sol_cli_port_forward.string_contains ~needle detail)
    [ "Unauthorized"
    ; "You must be logged in"
    ; "the server has asked for the client to provide credentials"
    ; "is forbidden"
    ]
;;

(* Compares the **full** canonical ARN, account and path included.

   Comparing an extracted role name was a fail-*open*: the same role name in another
   account, or reached through a different role path, would look like the same principal,
   and a different principal being denied afterwards would then read as Deescalated. The
   strict comparison is the safe direction -- its worst case is a false mismatch, which
   lands in Undetermined and does not announce Ready. INFRA-061 records the precise
   comparison (account plus normalised role) as the follow-up that makes it exact. *)
let deescalation_principal_check ~expected_arn ~provisioner_role_arn env =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "whoami"; "-o"; "json" ])
  with
  | Ok r when r.Sol_cli_process.exit_code = 0 ->
    (match Sol_cli_cloud_lifecycle.whoami_identity_of_json r.Sol_cli_process.stdout with
     | Ok identity ->
       let shown =
         match identity.Sol_cli_cloud_lifecycle.canonical_arn, identity.arn with
         | Some a, _ | None, Some a -> a
         | None, None -> "(unnamed)"
       in
       (match
          Sol_cli_cloud_lifecycle.principal_matches ~expected:expected_arn identity
        with
        | Some true -> Sol_cli_cloud_lifecycle.Principal_confirmed shown
        | Some false -> Sol_cli_cloud_lifecycle.Principal_unexpected shown
        | None ->
          Sol_cli_cloud_lifecycle.Principal_probe_failed "the response named no principal")
     | Error why -> Sol_cli_cloud_lifecycle.Principal_probe_failed why)
  | Ok r ->
    let detail =
      String.trim (r.Sol_cli_process.stderr ^ " " ^ r.Sol_cli_process.stdout)
    in
    (* A refusal from the cluster is the expected post-de-escalation state. Anything
       else -- a credential that could not be assumed, a token that could not be
       generated, no reachable API -- is a measurement failure, and absence of evidence
       must not become evidence of de-escalation. Only the cluster's own answer counts. *)
    if cluster_refused detail
    then (
      (* A refusal is evidence of removal only if the credential is still good. "You must be
         logged in" is also what a working credential gets when the role's trust policy is
         broken, the clock is skewed, or the wrong role was assumed -- and reading that as
         removal would be a fail-open into Deescalated. The raw configured ARN is used here,
         not the path-free form the comparison wants, because this is an IAM call. *)
      let assumption =
        match
          Sol_cli_process.run
            (Sol_cli_process.cmd
               ~env
               [ "aws"
               ; "sts"
               ; "assume-role"
               ; "--role-arn"
               ; provisioner_role_arn
               ; "--role-session-name"
               ; "sol-deescalation-check"
               ])
        with
        | Ok r when r.Sol_cli_process.exit_code = 0 ->
          Sol_cli_cloud_lifecycle.Credential_assumable
        | Ok _ -> Sol_cli_cloud_lifecycle.Credential_refused
        | Error _ -> Sol_cli_cloud_lifecycle.Credential_unchecked
      in
      Sol_cli_cloud_lifecycle.refusal_is_deescalation assumption detail)
    else Sol_cli_cloud_lifecycle.Principal_probe_failed detail
  | Error e ->
    Sol_cli_cloud_lifecycle.Principal_probe_failed (Sol_cli_process.error_to_string e)
;;

(* Deliberately *not* [with_provisioner_kubeconfig]: that raises through
   [lifecycle_error] when the ephemeral access cannot be established, which would abort
   paths that must degrade gracefully -- the offline lifecycle harness injects a cloud
   failure and requires `cloud apply` to resume, and it does not have a real cluster to
   reach. Failing to obtain the probe is a measurement failure, which the transition
   verdict already handles as [Undetermined]; it must not become a crash. *)
let deescalation_probe ~region ~outputs ~provisioner_role_arn () =
  match
    provisioner_kubeconfig ~role_arn:provisioner_role_arn ~region outputs (fun env ->
      let principal =
        deescalation_principal_check
          ~expected_arn:(Sol_cli_cloud_lifecycle.normalize_role_arn provisioner_role_arn)
          ~provisioner_role_arn
          env
      in
      let probes =
        match principal with
        | Sol_cli_cloud_lifecycle.Principal_unexpected _
        | Sol_cli_cloud_lifecycle.Principal_probe_failed _
        | Sol_cli_cloud_lifecycle.Principal_refused_by_cluster _ ->
          (* Never interrogate another principal's capabilities and call it evidence. *)
          []
        | _ ->
          List.map
            (fun capability -> capability, capability_answer_of_can_i ~env capability)
            bootstrap_only_capabilities
      in
      principal, probes)
  with
  | Ok v -> v
  | Error e -> Sol_cli_cloud_lifecycle.Principal_probe_failed e, []
;;

(* Bounded and fail-closed: access-entry changes are eventually consistent so a retry
   is expected, but an unverified claim is not an acceptable outcome. *)
(* DEC-040 gate: the shape of the authorizer's answer is the one thing a fixture cannot
   settle, because the fixtures encode a shape recalled from the API rather than captured
   from a cluster.

   It runs as soon as the cluster is reachable -- after the cloud apply and before the
   platform install, which is the expensive part -- and it **fails the run** unless it
   observes, in order:

   1. an answer at all, retried with backoff because a freshly created EKS endpoint is
      briefly unable to authenticate its own principal. Unreachability is retried and then
      fatal: the gate not having run is a failure, not a pass;
   2. a response the parser can identify a principal from;
   3. that the principal is **the expected provisioner**, not merely that some principal was
      named -- otherwise a leftover credential of another identity passes the shape check;
   4. that the identity came from `canonicalArn`. The de-escalation comparison depends on
      that field, so a pass via the `arn` or `username` fallbacks would be validating a path
      the comparison does not use.

   The raw response is written to a run artifact that survives teardown, so it can be
   promoted to a fixture even if the run later fails. *)
(* The filename carries the run, so a second run cannot overwrite the first one's
   evidence. *)
let whoami_capture_path ~run_id =
  let name = Printf.sprintf "whoami-capture-%s.json" run_id in
  match Sys.getenv_opt "SOL_QUALIFICATION_CAPTURE_DIR" with
  | Some dir -> Some (Filename.concat dir name)
  | None ->
    (match Sys.getenv_opt "HOME" with
     | Some home -> Some (Filename.concat (Filename.concat home ".sol-qual") name)
     | None -> None)
;;

let persist_whoami_capture ~run_id json =
  match whoami_capture_path ~run_id with
  | None ->
    Printf.printf
      "  whoami capture: no writable path (set HOME or SOL_QUALIFICATION_CAPTURE_DIR)\n%!"
  | Some path ->
    (try
       let dir = Filename.dirname path in
       (* The raw capture holds real ARNs and account ids, so the directory is 0700 and the
          file 0600 -- created or tightened, since an existing directory may be looser. *)
       if not (Sys.file_exists dir) then Unix.mkdir dir 0o700;
       (try Unix.chmod dir 0o700 with
        | _ -> ());
       let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
       let oc = Unix.out_channel_of_descr fd in
       output_string oc json;
       close_out oc;
       (try Unix.chmod path 0o600 with
        | _ -> ());
       Printf.printf "  whoami capture: %s\n%!" path
     with
     | _ ->
       Printf.printf
         "  whoami capture: could not write %s -- the raw response is in this log above\n\
          %!"
         path)
;;

let verify_whoami_shape ~on_error ~region ~outputs ~provisioner_role_arn =
  (* This gate runs after the bootstrap window is open, so a failure here must remove
     that access before the run stops -- otherwise the run exits with
     [provisioner_bootstrap_admin=true] still applied on a cluster it has just decided
     it cannot verify. [on_error] is the same cleanup every other failure path uses. *)
  let fail message =
    on_error ();
    lifecycle_error message
  in
  let interval_s = whoami_retry_interval_s () in
  (* The expectation is the configured intent -- the target's provisioner role, normalised
     to the path-free form canonicalArn reports, so a role with a path does not produce a
     false mismatch on a healthy cluster. The observation is the authorizer's own answer
     about who authenticated. They are not the same value read back from one place: the
     kubeconfig is built from the config, but the ARN compared against it comes from the
     cluster, so a leftover credential of another identity answers with that other ARN and
     is caught. *)
  let expected = Sol_cli_cloud_lifecycle.normalize_role_arn provisioner_role_arn in
  let run_id = Printf.sprintf "%d" (int_of_float (Unix.gettimeofday ())) in
  let rec attempt remaining =
    let outcome =
      provisioner_kubeconfig ~role_arn:provisioner_role_arn ~region outputs (fun env ->
        Sol_cli_process.run
          (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "whoami"; "-o"; "json" ]))
    in
    match outcome with
    | Ok (Ok r) when r.Sol_cli_process.exit_code = 0 ->
      let json = String.trim r.Sol_cli_process.stdout in
      (* Persisted before anything is asserted, on every attempt: the run that fails on a
         shape mismatch is the one whose capture matters most, and writing afterwards would
         leave nothing behind for exactly that case. *)
      persist_whoami_capture ~run_id json;
      let identity_result = Sol_cli_cloud_lifecycle.whoami_identity_of_json json in
      (match identity_result with
       | Error why ->
         fail
           (Printf.sprintf
              "the authorizer's whoami response did not match the parser (%s). The run \
               stops here rather than spending a bootstrap on a verification that cannot \
               succeed. Raw response: %s"
              why
              json)
       | Ok identity ->
         let source = identity.Sol_cli_cloud_lifecycle.source in
         Printf.printf "  whoami shape: parsed (identity source: %s)\n%!" source;
         let matched = Sol_cli_cloud_lifecycle.principal_matches ~expected identity in
         let named =
           match identity.Sol_cli_cloud_lifecycle.canonical_arn, identity.arn with
           | Some a, _ -> a
           | None, Some a -> a
           | None, None -> "(unnamed)"
         in
         (match matched with
          | Some true -> ()
          | Some false ->
            fail
              (Printf.sprintf
                 "the authorizer answered as a different principal than the provisioner \
                  whose elevation this run manages (%s, from %s). The run stops here: \
                  the de-escalation comparison would be about somebody else."
                 named
                 source)
          | None -> fail "the authorizer's answer named no principal at all");
         if source <> "extra.canonicalArn" && source <> "userInfo.canonicalArn"
         then
           fail
             (Printf.sprintf
                "the principal came from %s rather than canonicalArn, which is the field \
                 the de-escalation comparison depends on. The run stops rather than \
                 validating a path the verification does not use. Raw response: %s"
                source
                json))
    | unreachable ->
      let why =
        match unreachable with
        | Ok (Ok r) ->
          Printf.sprintf
            "kubectl exited %d (%s)"
            r.Sol_cli_process.exit_code
            (String.trim (r.Sol_cli_process.stderr ^ " " ^ r.Sol_cli_process.stdout))
        | Ok (Error e) -> Sol_cli_process.error_to_string e
        | Error e -> e
      in
      (* Retried, not treated as terminal. A 401 or an authentication failure immediately
         after cluster creation is usually access-entry or aws-auth propagation lag for the
         *correct* principal, and connection errors are the endpoint not being ready -- both
         fix themselves. A 403 on this call is unusual (SelfSubjectReview is normally allowed
         for any authenticated user) and is retried on the same terms, then fails when the
         window expires.

         The one thing that *is* terminal is a successful answer naming a different identity,
         which is handled above: that is a wrong credential, and no amount of waiting changes
         it. Treating every Unauthorized as terminal here would fail healthy runs in the first
         minute. *)
      if remaining <= 1
      then
        fail
          (Printf.sprintf
             "the authorizer could not be reached to check the whoami shape (%s). The \
              gate not having run is a failure, not a pass: the run stops before the \
              platform install rather than discovering an unreadable shape at \
              de-escalation."
             why)
      else (
        Printf.printf
          "  whoami shape: not reachable yet (%s); retrying in %.0fs\n%!"
          why
          interval_s;
        Unix.sleepf interval_s;
        attempt (remaining - 1))
  in
  attempt cluster_propagation_attempts
;;

(* The verdict after the removal, once it stops changing or the bounded window expires.
   Never exits: the install path treats anything but [Deescalated] as fatal because Ready
   is a least-privilege claim, while the destroy path must not let a probe that can fail
   block teardown (ADR 0003 invariant 6) and reports the verdict instead. *)
let await_deescalation ~region ~outputs ~provisioner_role_arn ~before =
  let interval_s = whoami_retry_interval_s () in
  let rec loop remaining =
    (* The after-probe builds its kubeconfig the same way the window control did, against
       the same cluster and region. That is what makes a refusal attributable to the removal
       rather than to a wrong cluster name, a different endpoint or a region mismatch -- none
       of which the IAM identity check can see. If these two paths ever diverge, the
       guarantee goes with them, so change both or neither. *)
    let principal, probes =
      deescalation_probe ~region ~outputs ~provisioner_role_arn ()
    in
    let verdict =
      Sol_cli_cloud_lifecycle.deescalation_transition
        ~before
        ~after_principal:principal
        ~after:probes
    in
    match verdict with
    | Sol_cli_cloud_lifecycle.Deescalated -> verdict
    | _ when remaining <= 1 -> verdict
    | verdict ->
      Printf.printf
        "  awaiting effective de-escalation: %s\n%!"
        (Sol_cli_cloud_lifecycle.deescalation_verdict_to_string verdict);
      Unix.sleepf interval_s;
      loop (remaining - 1)
  in
  loop deescalation_attempts
;;

let verify_deescalation ~region ~outputs ~provisioner_role_arn ~before =
  match await_deescalation ~region ~outputs ~provisioner_role_arn ~before with
  | Sol_cli_cloud_lifecycle.Deescalated ->
    Printf.printf "  de-escalation verified as %s\n%!" provisioner_role_arn
  | verdict ->
    lifecycle_error
      ("de-escalation could not be established: "
       ^ Sol_cli_cloud_lifecycle.deescalation_verdict_to_string verdict)
;;

(* Operator-facing wording for the control line, kept out of the library: this is how a
   probe result is reported, not part of the verdict. *)
let deescalation_principal_to_string = function
  | Sol_cli_cloud_lifecycle.Principal_confirmed arn -> "confirmed " ^ arn
  | Sol_cli_cloud_lifecycle.Principal_refused_by_cluster why ->
    "refused by the cluster: " ^ why
  | Sol_cli_cloud_lifecycle.Principal_probe_failed why -> "no evidence: " ^ why
  | Sol_cli_cloud_lifecycle.Principal_unexpected who -> "unexpected " ^ who
;;

let capability_answer_to_string = function
  | Sol_cli_cloud_lifecycle.Permitted -> "permitted"
  | Sol_cli_cloud_lifecycle.Denied -> "denied"
  | Sol_cli_cloud_lifecycle.Indeterminate why -> "indeterminate: " ^ why
;;

(* The window control's failure, with every reason it could not be established: an
   operator needs to see which capability was indeterminate and why, not only that the
   window never opened. *)
let window_control_failure ~permitted indeterminate =
  let stop =
    "The run stops rather than proceeding to a verification that can only come back \
     undetermined."
  in
  if not permitted
  then
    Printf.sprintf
      "the bootstrap window never showed a capability permitted, so a later denial could \
       not be told apart from a credential that never worked. %s"
      stop
  else
    Printf.sprintf
      "the bootstrap window showed a capability permitted but also an indeterminate \
       probe (%s), which a later denial could not be told apart from. %s"
      (indeterminate
       |> List.map (fun (capability, why) -> capability ^ ": " ^ why)
       |> String.concat ", ")
      stop
;;

(* [Ok control] once the window shows at least one bootstrap-only capability permitted
   *and* no indeterminate probe -- an indeterminate capability would make the later
   transition [Undetermined] anyway, so failing here catches it before the platform
   install rather than at de-escalation. [Error reason] otherwise; never exits, so the
   destroy path can report rather than be blocked. *)
let observe_bootstrap_window_result ~region ~outputs ~provisioner_role_arn () =
  let interval_s = whoami_retry_interval_s () in
  let rec attempt remaining =
    let control = deescalation_probe ~region ~outputs ~provisioner_role_arn () in
    let principal, probes = control in
    let permitted =
      List.exists
        (fun (_, answer) -> Sol_cli_cloud_lifecycle.answer_is_permitted answer)
        probes
    in
    let indeterminate =
      List.filter_map Sol_cli_cloud_lifecycle.indeterminate_reason probes
    in
    match permitted, indeterminate with
    | true, [] ->
      Printf.printf
        "  bootstrap window control: principal=%s; %s\n%!"
        (deescalation_principal_to_string principal)
        (probes
         |> List.map (fun (capability, answer) ->
           Printf.sprintf
             "%s=%s"
             (Sol_cli_cloud_lifecycle.capability_label capability)
             (capability_answer_to_string answer))
         |> String.concat ", ");
      Ok control
    | _ ->
      if remaining <= 1
      then Error (window_control_failure ~permitted indeterminate)
      else (
        Printf.printf
          "  bootstrap window control: not yet permitted; retrying in %.0fs\n%!"
          interval_s;
        Unix.sleepf interval_s;
        attempt (remaining - 1))
  in
  attempt cluster_propagation_attempts
;;

(* The install path's control: a failure removes the bootstrap window and stops the run,
   because proceeding would spend a platform install on a verification that cannot
   succeed. *)
let observe_bootstrap_window ~on_error ~region ~outputs ~provisioner_role_arn () =
  match observe_bootstrap_window_result ~region ~outputs ~provisioner_role_arn () with
  | Ok control -> control
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

(* INFRA-039: resolve provider credentials for this operation, report the principal
   they belong to, and fail closed if they cannot be resolved. Sol used to inherit
   the ambient environment and assume it still worked: on HARDEN-002 Run 5 Attempt 5
   the SSO session expired mid-run, the CLI still answered for the profile while
   terraform could not refresh, and `sol cloud destroy` could not authenticate
   against a billable target. [leaves_target_standing] says the part that matters —
   a destroy that cannot authenticate leaves infrastructure running and disables the
   only supported path to remove it. *)
(* The GCP counterpart of [provisioner_kubeconfig], and the same semantic: an
   ephemeral kubeconfig for *this target's* cluster, in a temp file, exported
   under every name the platform providers read (finding 12), never the
   operator's ambient one.

   What differs is how a credential is obtained. AWS assumes a role through
   `aws eks update-kubeconfig --role-arn`; GCP asks the cluster for credentials
   with the caller's Application Default Credentials. Sol does not yet narrow
   that caller to a provisioner service account of its own on GCP -- there is no
   GCP equivalent of the AWS root's provisioner role -- so this is the target's
   Owner identity in the privileged install window, which is a recorded gap and
   not something this function should paper over. *)
(* Attempt 3's first meaningful failure, moved to where it belongs.

   The platform applies authenticate to GKE through the kubeconfig gcloud writes,
   and that kubeconfig names `gke-gcloud-auth-plugin` as its client-go exec
   credential plugin. Without it, every Kubernetes call dies with
   `exec: executable gke-gcloud-auth-plugin not found` -- *inside* the platform
   apply, which is to say after GKE and Cloud SQL have been provisioned and paid
   for, and after Sol has spent its way to the interesting part.

   That is a host prerequisite in the same class as terraform itself, so it is
   checked before the first platform call rather than discovered by one. Failing
   here costs nothing; failing there costs an apply. *)
(* REFAC-091: result-returning cores for the two GCP entry points, so the destroy
   execution sequence carries a cluster-access failure as a typed outcome and the
   caller's elevated-access cleanup runs from one structural place instead of
   every failing branch remembering an [on_error]. The install path keeps the
   exiting wrappers, which are now thin adapters over the cores. *)
let gcp_platform_toolchain_result () : (unit, string) result =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "gke-gcloud-auth-plugin"; "--version" ])
  with
  | Ok result when result.Sol_cli_process.exit_code = 0 -> Ok ()
  | _ ->
    Error
      "the platform cannot reach a GKE cluster without `gke-gcloud-auth-plugin`, which \
       is not on PATH: the kubeconfig gcloud writes names it as its credential plugin, \
       so every Kubernetes call would fail with \"executable gke-gcloud-auth-plugin not \
       found\". Install it (`gcloud components install gke-gcloud-auth-plugin`) and \
       re-run. Nothing has been changed."
;;

let require_gcp_platform_toolchain ?(on_error = Fun.id) () =
  match gcp_platform_toolchain_result () with
  | Ok () -> ()
  | Error message ->
    on_error ();
    lifecycle_error message
;;

(* INFRA-070 / FND-0047: [on_error] runs before every exit, as it does in
   [with_provisioner_kubeconfig]. A caller that opened the bootstrap window hands
   in the cleanup that closes it; exiting without calling it would leave the
   provisioner elevated. *)
let gcp_provisioner_kubeconfig_result
      ~region
      outputs
      (f : env:(string * string) list -> (unit, string) result)
  : (unit, string) result
  =
  let* () = gcp_platform_toolchain_result () in
  let path = Filename.temp_file "sol-platform-provisioner-" ".kubeconfig" in
  let cleanup () =
    try Sys.remove path with
    | Sys_error _ -> ()
  in
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
    let env = Sol_cli_cloud_lifecycle.provisioner_kube_env path in
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           ~env
           [ "gcloud"
           ; "container"
           ; "clusters"
           ; "get-credentials"
           ; Sol_cli_cloud_lifecycle.cluster_name
               (Sol_cli_cloud_lifecycle.Gcp_outputs outputs)
           ; "--region"
           ; region
           ; "--project"
           ; outputs.Sol_cli_cloud_lifecycle.project_id
             (* Impersonation is the point: Sol acts as the target's named
              provisioner, through short-lived tokens, rather than as whoever
              happened to run the command. *)
           ; "--impersonate-service-account"
           ; outputs.Sol_cli_cloud_lifecycle.provisioner_service_account
             (* No `--kubeconfig`. Attempt 2's first live failure was
                "unrecognized arguments: --kubeconfig": the flag does not exist on
                this subcommand. gcloud writes to the kubeconfig named by
                `$KUBECONFIG`, which [provisioner_kube_env] has already exported for
                this child, and that is the interface it actually has.

                The offline stub accepted the flag because it was written from this
                implementation, which is the limitation worth remembering: a stub
                cannot falsify the interface it was modelled on.
                `check_gcloud_interface.sh` now validates the argv against gcloud's
                own help output instead. *)
           ; "--quiet"
           ])
    with
    | Ok result when result.exit_code = 0 -> f ~env
    | Ok result ->
      (* Attempt 2 also showed why this failed without saying so. The message named
         the step and nothing else, so the reason -- a missing impersonation grant
         versus a wrong flag -- had to be reconstructed by hand. *)
      Error
        (Printf.sprintf
           "could not establish ephemeral cluster access as %s: gcloud exited %d%s"
           outputs.Sol_cli_cloud_lifecycle.provisioner_service_account
           result.Sol_cli_process.exit_code
           (let detail = String.trim result.Sol_cli_process.stderr in
            if detail = "" then "" else ":\n" ^ detail))
    | Error error ->
      Error
        (Printf.sprintf
           "could not run gcloud to establish cluster access: %s"
           (Sol_cli_process.error_to_string error)))
;;

let gcp_provisioner_kubeconfig ?(on_error = Fun.id) ~region outputs f =
  match gcp_provisioner_kubeconfig_result ~region outputs (fun ~env -> Ok (f env)) with
  | Ok () -> ()
  | Error message ->
    on_error ();
    lifecycle_error message
;;

let with_cluster_access ?(on_error = Fun.id) ~region outputs f =
  match outputs with
  | Sol_cli_cloud_lifecycle.Aws_outputs outputs ->
    with_provisioner_kubeconfig ~on_error ~region outputs f
  | Sol_cli_cloud_lifecycle.Gcp_outputs outputs ->
    gcp_provisioner_kubeconfig ~on_error ~region outputs f
;;

(* The destroy path's result-returning cluster access: no [on_error] threading,
   because the elevated-access removal is bracketed structurally around the
   operation rather than handed to each failure branch (FND-0047 / REFAC-091). *)
let with_cluster_access_result
      ~region
      outputs
      (f : env:(string * string) list -> (unit, string) result)
  : (unit, string) result
  =
  match outputs with
  | Sol_cli_cloud_lifecycle.Aws_outputs outputs ->
    (match provisioner_kubeconfig ~region outputs (fun env -> f ~env) with
     | Ok result -> result
     | Error message -> Error message)
  | Sol_cli_cloud_lifecycle.Gcp_outputs outputs ->
    gcp_provisioner_kubeconfig_result ~region outputs f
;;

(* INFRA-039 resolved credentials per mutating stage, because a platform stage runs
   many minutes after the cloud stage and a run can lose its session in between.
   GCP's credential is Application Default Credentials and the reasoning is
   identical -- including the part that matters most: a destroy that cannot
   authenticate leaves billable infrastructure standing *and* disables the only
   supported path to remove it. So the same guarantee is made through the
   provider's own mechanism rather than assumed on GCP because it was implemented
   on AWS. The token itself is never printed. *)
(* REFAC-091: the result-returning core, so the destroy execution sequence can
   carry a credential failure as a typed outcome instead of exiting from inside a
   helper. The install path keeps [require_credentials], which is now a thin
   exiting wrapper over this. *)
let credentials_result ~provider ~operation ~leaves_target_standing
  : (unit, string) result
  =
  let standing_remark =
    if leaves_target_standing
    then
      " The target is still standing and may still be billing; nothing has been changed."
    else " Nothing has been changed."
  in
  match provider with
  | Sol_cli_provider.Aws ->
    let profile = Sys.getenv_opt "AWS_PROFILE" in
    (match Sol_cli_credentials.resolve ~run:process_output ~profile with
     | Error detail ->
       Error
         (Sol_cli_credentials.unresolved_message
            ~operation
            ~profile
            ~leaves_target_standing
            ~detail)
     | Ok credentials ->
       Sol_cli_credentials.install credentials;
       Printf.printf "  credentials: %s\n%!" credentials.principal;
       Ok ())
  | Sol_cli_provider.Gcp ->
    (match
       process_output [ "gcloud"; "auth"; "application-default"; "print-access-token" ]
     with
     | Some _ ->
       Printf.printf "  credentials: Google Application Default Credentials resolved\n%!";
       Ok ()
     | None ->
       Error
         (Printf.sprintf
            "cannot resolve Google Application Default Credentials, so Sol cannot \
             %s              this target.%s Run `gcloud auth application-default login` \
             (or fix the              attached service account) and re-run."
            operation
            standing_remark))
;;

let require_credentials ~provider ~operation ~leaves_target_standing =
  match credentials_result ~provider ~operation ~leaves_target_standing with
  | Ok () -> ()
  | Error message -> lifecycle_error message
;;

let aws_cloud_ready ~region outputs =
  let cluster =
    Sol_cli_cloud_lifecycle.cluster_name (Sol_cli_cloud_lifecycle.Aws_outputs outputs)
  in
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

(* What "the cloud substrate is Ready" means on GCP: the GKE control plane is
   RUNNING and the Cloud SQL instance is RUNNABLE. The AWS check also asserts the
   EBS CSI addon is ACTIVE because Sol creates it; on GKE the block-storage
   provisioner is part of the platform the provider manages, and the storage
   contract is asserted at the Kubernetes layer instead -- the provider's
   StorageClass is the sole default and is backed by its CSI driver, which is the
   check that actually covers what a workload binds to. *)
let gcp_cloud_ready outputs =
  let project = outputs.Sol_cli_cloud_lifecycle.project_id in
  let region = outputs.region in
  let cluster = outputs.cluster_name in
  let status argv = process_output ([ "gcloud" ] @ argv) in
  match
    ( status
        [ "container"
        ; "clusters"
        ; "describe"
        ; cluster
        ; "--region"
        ; region
        ; "--project"
        ; project
        ; "--format"
        ; "value(status)"
        ]
    , status
        [ "sql"
        ; "instances"
        ; "describe"
        ; cluster ^ "-postgres"
        ; "--project"
        ; project
        ; "--format"
        ; "value(state)"
        ] )
  with
  | Some cluster_status, Some sql_state
    when String.trim cluster_status = "RUNNING" && String.trim sql_state = "RUNNABLE" ->
    true
  | _ -> false
;;

let cloud_ready ~region = function
  | Sol_cli_cloud_lifecycle.Aws_outputs outputs -> aws_cloud_ready ~region outputs
  | Sol_cli_cloud_lifecycle.Gcp_outputs outputs -> gcp_cloud_ready outputs
;;

(* What that check means, in the words its failure is reported with. *)
let cloud_ready_expectation = function
  | Sol_cli_provider.Aws -> "the EKS cluster and its EBS CSI addon are ACTIVE"
  | Sol_cli_provider.Gcp ->
    "the GKE cluster is RUNNING and the Cloud SQL instance is RUNNABLE"
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

(* Staged through the shared platform definition. The provider's root addresses
   its resources through whatever structure reaches that definition, so every
   address is resolved per provider rather than written as a bare one. *)
let platform_prerequisite_targets provider =
  let address = Sol_cli_cloud_lifecycle.platform_address provider in
  Sol_cli_terraform.targets
    (address "kubernetes_namespace.cert_manager")
    (List.map
       address
       [ "kubernetes_namespace.ingress_nginx"
       ; "kubernetes_namespace.argocd"
       ; "kubernetes_namespace.redpanda"
       ; "kubernetes_namespace.monitoring"
       ; "kubernetes_cluster_role.platform_provisioner_namespaced"
       ; "kubernetes_role_binding.platform_provisioner"
       ; "kubernetes_cluster_role.platform_provisioner_cluster"
       ; "kubernetes_cluster_role_binding.platform_provisioner_cluster"
         (* The deploy identity's RBAC (sol_deploy / sol_deploy_bootstrap) is
            created by the full platform apply, which ADR 0003 keeps inside the
            privileged PlatformInstalling authority -- so it is not staged here.
            (HARDEN-002 run 4 finding 13's interim staging is superseded by that
            model.) *)
       ; "helm_release.cert_manager"
       ])
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
(* HARDEN-004 step 2 / REFAC-091: the state inventory.

   The destroy path takes ONE observation of the root's own applied state and
   turns it into the typed inventory in [Sol_cli_cloud_destroy]. Every decision
   below -- what is represented, which guarded resources may be targeted, what
   verification has to see -- is derived from that inventory. It is deliberately
   NOT derived from the install-time output contract: a half-built target may
   have no outputs, partial outputs, or complete outputs, and none of those decide
   whether destruction is available (FND-0044 point 2). *)
let read_cloud_state infra_dir : (Sol_cli_cloud_destroy.state_read, string) result =
  match Sol_cli_terraform.show_json ~chdir:infra_dir () with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    Ok (Sol_cli_cloud_destroy.inventory_of_show_json result.Sol_cli_process.stdout)
  | Ok result ->
    Error (Printf.sprintf "terraform show failed with exit %d" result.exit_code)
  | Error error ->
    Error ("could not read terraform state: " ^ Sol_cli_process.error_to_string error)
;;

(* The RDS instance, by its real declared address. Finding it by address rather
   than by type is the FND-0048 correction: a second [aws_db_instance] (a read
   replica) is a different address and is never mistaken for this one. An
   unreadable state is UNKNOWN, never "no instance". *)
let rds_of_state state =
  let open Sol_cli_cloud_destroy in
  match find_address state "aws_db_instance.postgres" with
  | Some resource when resource.kind = "aws_db_instance" ->
    (match resource.deletion_protection with
     | Some deletion_protection ->
       Ok
         (Some
            ( deletion_protection
            , resource.final_snapshot_identifier
            , resource.skip_final_snapshot ))
     | None -> Error "RDS deletion_protection is absent from its state representation")
  | Some resource ->
    Error
      (Printf.sprintf
         "address aws_db_instance.postgres is a %s, not an aws_db_instance"
         resource.kind)
  | None ->
    (match substrate_presence state with
     | Substrate_unknown -> Error "could not read this target's state"
     | Substrate_present | Substrate_absent -> Ok None)
;;

(* ADR 0002 / HARDEN-002 finding 9b: lifting RDS deletion protection is a
   state transition (ModifyDBInstance), and a destroy plan contains only
   deletes -- a `-var` passed to `terraform destroy` never reaches the
   provider, which is handed prior state (see the now-resolved comment this
   replaced). Preparation is therefore its own targeted apply against just
   the RDS resource, with a snapshot identity unique to this destroy attempt
   so re-running destroy after a fresh apply can never collide with a prior
   attempt's final snapshot. *)
let prepare_destroy_result run_log infra_dir var_files vars ~cluster_name ~retention state
  =
  match rds_of_state state with
  | Error message -> Error message
  | Ok None ->
    Printf.printf "  prepare: no RDS instance for this target, nothing to prepare.\n%!";
    Ok None
  | Ok (Some _) ->
    let snapshot_id = unique_rds_snapshot_id cluster_name in
    Printf.printf
      "  prepare: disabling RDS deletion protection%s...\n%!"
      (match retention with
       | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
         ", final snapshot " ^ snapshot_id
       | Sol_cli_cloud_lifecycle.Retain_nothing -> ", retaining nothing");
    let* () =
      apply_asserted
        ~run_log
        ~phase_name:"rds-destroy-prepare"
        ~policy:
          (Sol_cli_cloud_destroy.guard_preparation_policy
             ~addresses:[ "aws_db_instance.postgres" ])
        ~scope:rds_target
        ~chdir:infra_dir
        ~var_files
        ~vars:
          (vars
           @ [ "rds_deletion_protection=false" ]
           @
           match retention with
           | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
             [ "rds_skip_final_snapshot=false"
             ; "rds_final_snapshot_identifier=" ^ snapshot_id
             ]
           | Sol_cli_cloud_lifecycle.Retain_nothing -> [ "rds_skip_final_snapshot=true" ]
          )
        ()
    in
    Ok (Some snapshot_id)
;;

(* DEC-033: what "prepared" means depends on what the target selected, so the
   verification is driven by the policy rather than by a single expected value.

     final-snapshot -> deletion protection disabled, snapshot creation ENABLED,
                       and the identifier is the one this run prepared
     none           -> deletion protection disabled, snapshot creation DISABLED,
                       and no identifier is required

   Deliberately not `if actual <> "" then check_identifier`: that would let a
   missing identifier pass for a target that explicitly asked to keep its snapshot,
   which is the production guarantee this must not weaken. *)
let verify_destroy_preparation_result infra_dir ~retention ~prepared =
  match prepared with
  | None ->
    Printf.printf "  verify preparation: nothing was prepared.\n%!";
    Ok ()
  | Some snapshot_id ->
    let* state = read_cloud_state infra_dir in
    (match rds_of_state state with
     | Error message -> Error message
     | Ok None ->
       Error "RDS destroy preparation ran but the instance is now absent from state"
     | Ok (Some (deletion_protection, final_snapshot_identifier, skip_final_snapshot)) ->
       let* () =
         if deletion_protection
         then Error "RDS deletion protection is still enabled after preparation"
         else Ok ()
       in
       let* () =
         match retention with
         | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
           let* () =
             match skip_final_snapshot with
             | Some true ->
               Error
                 "the target retains its final snapshot, but preparation disabled \
                  snapshot creation"
             | None ->
               Error
                 "cannot establish that the final snapshot will be retained: \
                  skip_final_snapshot is absent from state"
             | Some false -> Ok ()
           in
           if final_snapshot_identifier <> Some snapshot_id
           then
             Error
               (Printf.sprintf
                  "RDS final snapshot identifier is %s, expected the prepared %s"
                  (Option.value final_snapshot_identifier ~default:"<none>")
                  snapshot_id)
           else Ok ()
         | Sol_cli_cloud_lifecycle.Retain_nothing ->
           (match skip_final_snapshot with
            | Some true -> Ok ()
            | Some false ->
              Error
                "the target retains nothing, but preparation left snapshot creation \
                 enabled"
            | None ->
              Error
                "cannot establish that snapshot creation is disabled: \
                 skip_final_snapshot is absent from state")
       in
       Printf.printf
         "  verify preparation: RDS deletion protection disabled, final snapshot %s \
          (target destroy_retention = %s)\n\
          %!"
         (match retention with
          | Sol_cli_cloud_lifecycle.Retain_final_snapshot -> snapshot_id ^ " confirmed"
          | Sol_cli_cloud_lifecycle.Retain_nothing ->
            (* Say what will happen, not just the setting: `skip_final_snapshot=true`
               reads as "enabled" to anyone skimming, which is the opposite of what
               it means. *)
            Printf.sprintf
              "skipped (skip_final_snapshot=%s)"
              (match skip_final_snapshot with
               | Some value -> string_of_bool value
               | None -> "absent"))
         (Sol_cli_cloud_lifecycle.destroy_retention_to_string retention);
       Ok ())
;;

(* The GCP counterpart of [rds_state]: what this root's state represents.

   Two resources carry a deletion guard on GCP, by two different mechanisms: Cloud
   SQL's is the provider's attribute *and* an API-level setting, and the GKE
   cluster's is the provider's own attribute, which defaults to true. Live attempt
   1 found the second only after Cloud SQL had been lifted -- the teardown then
   refused with "Cannot destroy cluster because deletion_protection is set to
   true", so a target Sol had provisioned could not be destroyed through Sol at
   all. Both are read, and both are lifted.

   FND-0048: the read is the shared typed inventory ([read_cloud_state]), which
   walks the root module and every child module and keeps Terraform's own
   addresses. There is no type-to-fixed-address mapping here, no single-instance
   assumption, and a benign null guard is [None] rather than a read failure. *)

(* Deletion protection is not retention, and the distinction is the whole point of
   DEC-033: this transition makes the target *destructible*, it does not decide what
   survives. Both of GCP's guards are Terraform/provider attributes, and a destroy
   plan carries only deletes, so the provider is handed prior state and a `-var` on
   the destroy never reaches it -- lifting them is therefore its own targeted applied
   transition, verified from state afterwards rather than assumed. Doing nothing here
   does not skip a preparation, it makes the destroy impossible and the target
   billable. *)
(* The guarded resources, once: their real declared addresses. The state side of
   the intersection comes from the inventory, which walks child modules and keeps
   Terraform's own addresses -- so nothing is discovered by type and mapped back
   onto a fixed address (FND-0048), and a second instance of a type is a different
   address rather than a mis-attributed first one.

   The preparation below lowers deletion guards so that destruction can proceed. It is NOT
   a retention mechanism: deletion protection and "keep the final snapshot" are different
   promises, and only the second one is a destruction precondition (DEC-033). *)
let gcp_guarded_resources =
  [ "google_sql_database_instance.postgres"; "google_container_cluster.main" ]
;;

(* The guarded resources the Step-2 inventory actually represents, by declared
   address. This is the state side of the scope decision: a configured-but-
   unrepresented resource is not targeted (FND-0030), and the plan assertion
   catches anything a `-target` pulls in anyway. *)
let guarded_addresses_of provider state =
  let desired =
    match provider with
    | Sol_cli_provider.Gcp -> gcp_guarded_resources
    | Sol_cli_provider.Aws -> [ "aws_db_instance.postgres" ]
  in
  Sol_cli_cloud_lifecycle.preparations_eligible
    ~state:(Sol_cli_cloud_destroy.addresses state)
    ~desired
;;

let gcp_prepare_destroy_result run_log infra_dir var_files vars state =
  let open Sol_cli_cloud_destroy in
  let report_unrepresented unrepresented =
    (* FND-0030's actual leak, said out loud. Terraform destroys what its state holds, so a
       resource this target declares and its state does not know about survives the destroy
       -- and stays billable. Skipping it avoids the 409 of Attempt 6; without this report,
       that turns a loud failure into a quiet success. Adopting it is the only way to reach
       it, and that is a separate capability. *)
    match unrepresented with
    | [] -> ()
    | addresses ->
      Printf.printf
        "  WARNING: %d resource(s) this target declares are ABSENT from its state and \
         will therefore NOT be destroyed: %s\n\
        \  They may still exist in the provider and remain billable (FND-0030).\n\
         %!"
        (List.length addresses)
        (String.concat ", " addresses)
  in
  match substrate_presence state with
  | Substrate_unknown ->
    (* Report the unknown read rather than raising: a preparation that could not run must
       not decide whether destruction is attempted. UNKNOWN is not absence, so nothing is
       claimed about what is represented. *)
    Printf.printf "  prepare: could not read this target's state; preparing nothing.\n%!";
    Ok false
  | Substrate_present | Substrate_absent ->
    let represented = addresses state in
    let desired = gcp_guarded_resources in
    report_unrepresented
      (Sol_cli_cloud_lifecycle.preparations_unrepresented ~state:represented ~desired);
    (match Sol_cli_cloud_lifecycle.preparations_eligible ~state:represented ~desired with
     | [] ->
       Printf.printf
         "  prepare: no guarded resource in this target's state, nothing is targeted.\n%!";
       Ok false
     | first :: rest ->
       Printf.printf
         "  prepare: disabling the deletion guards on %s...\n%!"
         (String.concat ", " (first :: rest));
       (* STILL ABORTS ON FAILURE, and the policy vocabulary does not hide it: a failed
          guard-lowering apply blocks destruction here, which is the opposite of what this
          path should do. Making it report and continue -- and making AWS's
          final-snapshot preparation block instead, because there the failure stands for a
          declared retention guarantee -- is the wiring that follows (FND-0030). *)
       let* () =
         apply_asserted
           ~run_log
           ~phase_name:"gcp-destroy-prepare"
           ~policy:
             (Sol_cli_cloud_destroy.guard_preparation_policy ~addresses:(first :: rest))
           ~scope:(Sol_cli_terraform.targets first rest)
           ~chdir:infra_dir
           ~var_files
           ~vars:
             (vars @ [ "sql_deletion_protection=false"; "gke_deletion_protection=false" ])
           ()
       in
       Ok true)
;;

let verify_gcp_destroy_preparation_result infra_dir ~prepared =
  if not prepared
  then (
    Printf.printf "  verify preparation: nothing was prepared.\n%!";
    Ok ())
  else
    let* state = read_cloud_state infra_dir in
    let open Sol_cli_cloud_destroy in
    let guard address =
      Option.bind (find_address state address) (fun resource ->
        resource.deletion_protection)
    in
    if
      find_address state "google_sql_database_instance.postgres" = None
      && find_address state "google_container_cluster.main" = None
    then Error "GCP destroy preparation ran but no guarded resource is in state"
    else
      let* () =
        match guard "google_sql_database_instance.postgres" with
        | Some true ->
          Error "Cloud SQL deletion protection is still enabled after preparation"
        | Some false | None -> Ok ()
      in
      let* () =
        match guard "google_container_cluster.main" with
        | Some true -> Error "GKE deletion protection is still enabled after preparation"
        | Some false | None -> Ok ()
      in
      Printf.printf
        "  verify preparation: Cloud SQL and GKE deletion protection disabled.\n%!";
      Ok ()
;;

(* What destruction preparation did. The providers differ in what there is to carry
   forward -- AWS's prepared final-snapshot identity has no GCP counterpart, because
   Cloud SQL destroys its backups with the instance -- so the difference is named in
   the type rather than flattened into an option that would have to mean two
   things. The type lives in [Sol_cli_cloud_destroy], because the execution core
   carries it in its typed outcome. *)

let prepare_destruction_result
      ~provider
      run_log
      infra_dir
      var_files
      vars
      ~cluster_name
      ~retention
      ~state
  : (Sol_cli_cloud_destroy.preparation, string) result
  =
  match provider with
  | Sol_cli_provider.Aws ->
    let* prepared =
      prepare_destroy_result
        run_log
        infra_dir
        var_files
        vars
        ~cluster_name
        ~retention
        state
    in
    let* () = verify_destroy_preparation_result infra_dir ~retention ~prepared in
    Ok
      (match prepared with
       | None -> Sol_cli_cloud_destroy.Nothing_prepared
       | Some snapshot_id -> Sol_cli_cloud_destroy.Aws_prepared snapshot_id)
  | Sol_cli_provider.Gcp ->
    (* DEC-033: a target that destroys must say what it keeps, and GCP cannot keep
       anything today -- Cloud SQL deletes its backups with the instance, so there is
       no final-artifact equivalent of the RDS snapshot. Rather than let the
       [Retain_final_snapshot] *default* quietly become "destroy the recovery data
       anyway", which is the laundering DEC-033 exists to prevent, Sol refuses and
       names the gap. A disposable target opts in with `destroy_retention: none`,
       which is a statement rather than a default. *)
    (match retention with
     | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
       Error
         "this GCP target's destroy_retention is final-snapshot (the default), but Sol \
          cannot retain anything on GCP yet: Cloud SQL deletes its backups together with \
          the instance, so there is no final-artifact equivalent of the RDS snapshot and \
          the recovery data would be discarded without saying so. Declare \
          `destroy_retention: none` on a disposable target, or export the database first \
          -- Sol will not decide this for you"
     | Sol_cli_cloud_lifecycle.Retain_nothing ->
       let* prepared =
         gcp_prepare_destroy_result run_log infra_dir var_files vars state
       in
       let* () = verify_gcp_destroy_preparation_result infra_dir ~prepared in
       Ok
         (if prepared
          then Sol_cli_cloud_destroy.Gcp_prepared
          else Sol_cli_cloud_destroy.Nothing_prepared))
;;

(* The Destroy policy's overrides for this provider, given what preparation found.
   Appended after the caller's own variables so the phase policy wins (ADR 0003 /
   HARDEN-002 finding 15). *)
let destroy_policy_vars ~provider ~phase ~retention ~prepared =
  match prepared with
  | Sol_cli_cloud_destroy.Nothing_prepared -> []
  | Sol_cli_cloud_destroy.Aws_prepared snapshot_id ->
    Sol_cli_cloud_lifecycle.policy_vars
      ~provider
      ~phase
      ~destroy_snapshot_id:snapshot_id
      ~retention
  | Sol_cli_cloud_destroy.Gcp_prepared ->
    Sol_cli_cloud_lifecycle.policy_vars
      ~provider
      ~phase
      ~destroy_snapshot_id:""
      ~retention
;;

(* The install window, opened on the cloud root of *both* providers and closed
   before an install is reported. What differs is the object -- an EKS access entry
   on AWS, an in-cluster ClusterRoleBinding created under the operator's
   credentials on GCP -- and both are created by the cloud apply for the same
   reason: the platform apply runs *as* the provisioner, so it cannot be the thing
   that grants the provisioner the authority it is authenticated with. A binding
   created by the apply that needs it is a chicken-and-egg, which is exactly what
   the first draft of this got wrong.
   
   So there is no provider branch here and no provider argument: the variable is
   declared by both cloud roots, and the invariant -- authority exists only for the
   window -- is what is shared. *)

let bootstrap_access_vars ~enabled =
  [ ("provisioner_bootstrap_admin", if enabled then "true" else "false") ]
;;

(* ── INFRA-042: a partially installed platform must still be destroyable ──────
 *
 * Attempt 3 reached PlatformInstalling and failed there (a host prerequisite),
 * and Sol's documented destroy then could not finish:
 *
 *     [platform-destroy] FAILED (38.0s)
 *         Error: API did not recognize GroupVersionKind from manifest
 *                (CRD may not be installed)
 *
 * The platform root's state referenced CRD-backed resources -- the two
 * cert-manager ClusterIssuers, which the definition declares as
 * `kubernetes_manifest` -- whose CRDs were never installed, because the install
 * never got that far. The provider cannot delete a resource whose API does not
 * exist, so the destroy failed and the cloud layer behind it stayed billable.
 *
 * This is ADR 0004's invariant reached through a *third* mechanism. The first two
 * have guards (`prevent_destroy`, and a provider deletion default); this one is a
 * resource whose API does not exist, and it only appears in the state a target is
 * most likely to be in -- a failed install.
 *
 * The recovery has to be narrow in a specific way, because the obvious version of
 * it is a bug: "remove whatever Terraform cannot delete" would silently ignore
 * real resources. So a resource is forgotten only when it is *provably* absent,
 * and the proof is the cluster's own discovery:
 *
 *   * only `kubernetes_manifest`, whose stored manifest states its kind verbatim.
 *     Native `kubernetes_*` resources are deliberately not handled: deriving their
 *     kind means mapping a Terraform type to a Kubernetes kind by convention, and
 *     a mapping that is wrong in the wrong direction forgets a resource that
 *     exists. A native resource that will not delete stays a failure.
 *   * and only when the cluster does not serve that kind with the `delete` verb. A
 *     kind the cluster serves is a resource that may exist, so it is never
 *     forgotten -- the destroy is retried and, if it fails again, fails closed.
 *
 * Nothing here reimplements the resource graph: the destroy is attempted first, in
 * full, with Terraform's own ordering and ownership, and this only runs after it
 * has actually failed. *)
let served_api_kinds env =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         ~env
         [ "kubectl"; "api-resources"; "--verbs=delete"; "--no-headers" ])
  with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    Ok
      (String.split_on_char '\n' result.Sol_cli_process.stdout
       |> List.filter_map (fun line ->
         (* The last column is KIND; SHORTNAMES is often empty, so the split is on
            runs of whitespace rather than on single spaces. *)
         match
           String.split_on_char ' ' (String.trim line)
           |> List.filter (fun field -> field <> "")
           |> List.rev
         with
         | kind :: _ :: _ -> Some kind
         | _ -> None)
       |> List.sort_uniq compare)
  | Ok result ->
    Error
      (Printf.sprintf
         "kubectl api-resources exited %d: %s"
         result.Sol_cli_process.exit_code
         (String.trim result.Sol_cli_process.stderr))
  | Error error -> Error (Sol_cli_process.error_to_string error)
;;

(* The resources whose kind the cluster does not serve, each with the kind that
   proves it -- the proof travels with the decision. *)
let unserved_manifest_resources ~served ~chdir =
  match Sol_cli_terraform.show_json ~chdir () with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    (try
       let open Yojson.Safe.Util in
       Yojson.Safe.from_string result.stdout
       |> member "values"
       |> member "root_module"
       |> member "resources"
       |> to_list
       |> List.filter_map (fun resource ->
         if member "type" resource <> `String "kubernetes_manifest"
         then None
         else (
           let values = member "values" resource in
           let kind =
             match member "manifest" values |> member "kind" with
             | `String kind when kind <> "" -> Some kind
             | _ ->
               (match member "object" values |> member "kind" with
                | `String kind when kind <> "" -> Some kind
                | _ -> None)
           in
           match kind, member "address" resource with
           | Some kind, `String address when not (List.mem kind served) ->
             Some (address, kind)
           | _ -> None))
       |> Result.ok
     with
     | Yojson.Json_error message -> Error ("invalid `terraform show -json`: " ^ message)
     | Yojson.Safe.Util.Type_error (message, _) ->
       Error ("unexpected `terraform show -json` shape: " ^ message))
  | Ok result ->
    Error (Printf.sprintf "terraform show exited %d" result.Sol_cli_process.exit_code)
  | Error error -> Error (Sol_cli_process.error_to_string error)
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

let cloud_init ?(confirm_ecr_removal = false) ~target ~var_file ~vars ~action () =
  check_terraform ();
  let provider = provider_of_target_path target in
  let pname, infra_dir = infra_dir provider in
  let platform_dir = platform_dir provider in
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
  let cloud_target =
    match Sol_cli_cloud_lifecycle.cloud_target target_cfg with
    | Ok target -> target
    | Error message -> lifecycle_error message
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
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
  (* INFRA-039: credentials are resolved again here, per mutating stage,
       rather than assumed from process start -- a platform stage runs many
       minutes after the cloud stage. *)
  (match action with
   | Plan -> ()
   | _ ->
     require_credentials ~provider ~operation:"applying" ~leaves_target_standing:false);
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
    (match cloud_outputs_of provider infra_dir with
     | Ok None ->
       report_phase
         "Platform prerequisites"
         (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist");
       report_phase
         "Platform substrate"
         (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist")
     | Error message -> lifecycle_error message
     | Ok (Some outputs) ->
       let platform_vars = platform_vars_of ~cloud_target ~outputs () in
       (* An unavailable cluster credential is not a deferred phase: it is an
          unavailable lifecycle prerequisite, so plan exits non-zero. Deferral is
          reserved for phases whose concrete prerequisite is simply not
          established yet and whose establishment would itself be a mutation. *)
       with_cluster_access ~region:target_cfg.region outputs (fun env ->
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
            (* INFRA-039: credentials are resolved again here, per mutating stage,
       rather than assumed from process start -- a platform stage runs many
       minutes after the cloud stage. *)
            (match action with
             | Plan -> ()
             | _ ->
               require_credentials
                 ~provider
                 ~operation:"applying"
                 ~leaves_target_standing:false);
            run_terraform_init run_log platform_dir platform_backend;
            require_terraform_success
              (Sol_cli_run_log.run_phase
                 run_log
                 ~name:"platform-prerequisites-plan"
                 (fun () ->
                    Sol_cli_terraform.plan
                      ~env
                      ~scope:(platform_prerequisite_targets provider)
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
    (* ADR 0003 / INFRA-031: [CloudBootstrap] is the phase in which the cloud
       substrate does not exist yet, so report it before the privileged apply
       that creates it — a fresh target's first phase was previously visible only
       as the *absence* of output until the platform stage ran. A re-apply onto
       an existing substrate is not a bootstrap: there the platform stage below
       reports the phase that run is actually in.

       Only a positive "there is no substrate" observation justifies the claim:
       a state read that fails means the substrate is *unknown*, not absent, and
       is failed closed rather than reported as a phase (or applied over). *)
    (match cloud_outputs_of provider infra_dir with
     | Ok (Some _) -> ()
     | Ok None ->
       Printf.printf
         "  lifecycle phase: %s\n%!"
         (Sol_cli_cloud_lifecycle.phase_to_string Sol_cli_cloud_lifecycle.Cloud_bootstrap)
     | Error message -> lifecycle_error message);
    (* INFRA-074 / FND-0043: the cloud apply runs from a saved plan that is read
       first. ECR repositories are derived from the workloads with a Dockerfile in
       this checkout and carry [force_delete], so a plan that drops one would
       delete its images. Such a plan is refused unless the operator confirms it,
       and what is applied is the plan that was read. Nothing has changed when it
       refuses: the plan creates no resources and the bootstrap window is not open. *)
    let plan_file = Filename.temp_file "sol-cloud-apply-" ".tfplan" in
    let remove_plan () =
      List.iter
        (fun f ->
           try Sys.remove f with
           | Sys_error _ -> ())
        [ plan_file; plan_file ^ ".args" ]
    in
    at_exit remove_plan;
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan" (fun () ->
         Sol_cli_terraform.plan_saved
           ~scope:Sol_cli_terraform.whole_root
           ~chdir:infra_dir
           ~var_files
           ~vars:(Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:true) @ vars)
           ~out:plan_file
           ()));
    let changes =
      match
        terraform_stdout
          (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan-show" (fun () ->
             Sol_cli_terraform.show_json_plan ~chdir:infra_dir ~plan_file ()))
      with
      | Error message -> lifecycle_error ("could not read the cloud plan: " ^ message)
      | Ok json ->
        (match Sol_cli_terraform_plan.changes_of_plan_json json with
         | Ok changes -> changes
         | Error message -> lifecycle_error ("could not read the cloud plan: " ^ message))
    in
    (match
       Sol_cli_terraform_plan.removed_of_type ~resource_type:"aws_ecr_repository" changes
     with
     | [] -> ()
     | removed when confirm_ecr_removal ->
       Printf.printf
         "  ECR: removing %s and every image in them (confirmed with           \
          --confirm-ecr-removal)\n\
          %!"
         (String.concat ", " removed)
     | removed ->
       lifecycle_error
         (Printf.sprintf
            "this apply would delete ECR repositories and every image in them: %s\n\
            \  The repository list comes from the workloads with a Dockerfile in this \
             checkout, so a branch that lacks one of them removes it. Run from the \
             checkout that deploys this target, or pass --confirm-ecr-removal if \
             removing them is intended. Nothing was changed."
            (String.concat ", " removed)));
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-apply" (fun () ->
         Sol_cli_terraform.apply_saved ~chdir:infra_dir ~plan_file ()));
    remove_plan ();
    let deescalate () =
      Sol_cli_run_log.run_phase
        run_log
        ~name:"provisioner-bootstrap-access-remove"
        (fun () ->
           Sol_cli_terraform.apply
             ~scope:Sol_cli_terraform.whole_root
             ~chdir:infra_dir
             ~var_files
             ~vars:
               (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:false) @ vars)
             ())
    in
    let cleanup_bootstrap_access () =
      report_cleanup_failure ~what:"removing the bootstrap access" deescalate
    in
    let outputs =
      match cloud_outputs_of provider infra_dir with
      | Ok (Some v) -> v
      | Ok None ->
        cleanup_bootstrap_access ();
        lifecycle_error "Terraform apply completed without lifecycle outputs"
      | Error e ->
        cleanup_bootstrap_access ();
        lifecycle_error e
    in
    (* DEC-040's positive control. The bootstrap-only capabilities observed *permitted* as
       the provisioner while the window this run opened is still open -- captured here
       because the cloud apply has produced the outputs the probe needs and de-escalation
       is much later. Without it, a later denial is indistinguishable from a credential
       that never worked, a principal that was never the elevated one, or a capability
       that was never granted: a final denial is not a transition. *)
    (* The gate first. It fires at the moment a fresh endpoint is least likely to answer,
       so it must not be preceded by anything that also needs a working cluster -- least of
       all the control below, whose single probe would otherwise be the first thing to meet
       the propagation window. *)
    (match target_cfg.provisioner_role_arn, outputs with
     | Some provisioner_role_arn, Sol_cli_cloud_lifecycle.Aws_outputs aws_outputs ->
       verify_whoami_shape
         ~on_error:cleanup_bootstrap_access
         ~region:target_cfg.region
         ~outputs:aws_outputs
         ~provisioner_role_arn
     | _ -> ());
    (* The control must observe the bootstrap-only capability *permitted*, because a later
       denial is not a transition unless the capability was shown to work first. One probe
       at this moment is not enough: a fresh cluster can refuse or be unreachable while
       propagation catches up. So it retries with backoff, and if it never observes
       permitted the run stops before the platform install rather than proceeding to a
       verification that can only come back Undetermined. *)
    let bootstrap_window_control =
      match target_cfg.provisioner_role_arn, outputs with
      | Some provisioner_role_arn, Sol_cli_cloud_lifecycle.Aws_outputs aws_outputs ->
        Some
          (observe_bootstrap_window
             ~on_error:cleanup_bootstrap_access
             ~region:target_cfg.region
             ~outputs:aws_outputs
             ~provisioner_role_arn
             ())
      | _ -> None
    in
    (match bootstrap_window_control with
     | Some _ -> ()
     | None -> Printf.printf "  bootstrap window control: not captured\n%!");
    let platform_vars =
      platform_vars_of ~on_error:cleanup_bootstrap_access ~cloud_target ~outputs ()
    in
    if not (cloud_ready ~region:target_cfg.region outputs)
    then (
      cleanup_bootstrap_access ();
      lifecycle_error
        (Printf.sprintf
           "%s cloud substrate is not Ready: %s"
           pname
           (cloud_ready_expectation provider)));
    with_cluster_access
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
         (* ADR 0003: the phase is recomputed from observation at the top of the
            operation, before this run creates anything. The cert-manager CRDs
            are cluster objects, so they report what an *earlier* run installed
            and are unaffected by the bootstrap-admin escalation this run has
            just performed -- unlike a `kubectl auth can-i` probe, which that
            escalation would mask. *)
         let observed =
           Sol_cli_cloud_lifecycle.observed_phase
             ~cloud_exists:true
             ~platform_installed:(crds_established env)
         in
         (* ADR 0003 invariant 3: a platform change on an already-installed
            target is an explicit PlatformUpdating re-entry, never an implicit
            return to PlatformInstalling -- which the transition relation
            rejects, so modelling it the other way made the model and the
            operation disagree. *)
         let operation_phase =
           match observed with
           | Sol_cli_cloud_lifecycle.Ready ->
             (match
                Sol_cli_cloud_lifecycle.enter
                  ~from:Sol_cli_cloud_lifecycle.Ready
                  ~to_:Sol_cli_cloud_lifecycle.Platform_updating
              with
              | Ok phase -> phase
              | Error message -> lifecycle_error message)
           | Sol_cli_cloud_lifecycle.Absent | Sol_cli_cloud_lifecycle.Platform_installing
             -> Sol_cli_cloud_lifecycle.Platform_installing
           | ( Sol_cli_cloud_lifecycle.Cloud_bootstrap
             | Sol_cli_cloud_lifecycle.Platform_updating
             | Sol_cli_cloud_lifecycle.Preparing_destroy
             | Sol_cli_cloud_lifecycle.Destroying ) as other ->
             (* Unreachable from [observed_phase] today, and refused rather than
                matched so that widening the observation cannot silently admit
                an apply from a phase the relation does not allow one from. *)
             lifecycle_error
               (Printf.sprintf
                  "refusing to apply from observed lifecycle phase %s"
                  (Sol_cli_cloud_lifecycle.phase_to_string other))
         in
         (* ADR 0003: the phase is operational context, so it is reported rather
            than only acted on -- it is what tells an operator which authority
            and desired-state policy the run is applying. *)
         Printf.printf
           "  lifecycle phase: %s\n%!"
           (Sol_cli_cloud_lifecycle.phase_to_string operation_phase);
         let prerequisites =
           Sol_cli_run_log.run_phase
             run_log
             ~name:"platform-prerequisites-apply"
             (fun () ->
                Sol_cli_terraform.apply
                  ~env
                  ~scope:(platform_prerequisite_targets provider)
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
         (* ADR 0003 / HARDEN-002 run 4 finding 14: installing the platform is
            privileged platform establishment -- the charts mint ClusterRoles
            granting verbs the bounded provisioner deliberately does not hold --
            so the temporary bootstrap-admin authority stays open through the
            full platform apply AND verified readiness, and is revoked only at
            the PlatformInstalling -> Ready transition below. *)
         let platform_apply =
           Sol_cli_run_log.run_phase run_log ~name:"platform-apply" (fun () ->
             Sol_cli_terraform.apply
               ~env
               ~scope:Sol_cli_terraform.whole_root
               ~chdir:platform_dir
               ~var_files:[]
               ~vars:platform_vars
               ())
         in
         (match platform_apply with
          | Ok result when result.exit_code = 0 -> ()
          | _ ->
            cleanup_bootstrap_access ();
            require_terraform_success platform_apply);
         (* Readiness asserts the platform's convergence from authoritative
            Kubernetes state; it is not parameterised by the observability backend
            or the configured issuer (see Sol_cli_cloud_lifecycle.readiness). *)
         let sample_readiness () =
           Sol_cli_cloud_lifecycle.readiness ~provider ~run:(fun args ->
             process_output ~env ("kubectl" :: args))
         in
         let unmet_count checks =
           List.length
             (List.filter
                (fun (_, state) ->
                   match state with
                   | Sol_cli_cloud_lifecycle.Established -> false
                   | Sol_cli_cloud_lifecycle.Unmet _ -> true)
                checks)
         in
         (* INFRA-034: the install must not be judged on one sample taken the
            instant the apply returns. Helm reporting a release as deployed says
            the objects were created, not that the controllers behind them are
            serving: on a fresh install every native readiness endpoint is still
            starting, so a single sample reports a healthy platform as Unmet and
            then fails the run *after* relinquishing privilege. On a real target
            that produced "Unmet" naming nine components that were all Running
            minutes later.

            So wait, bounded, and say what is still unmet while waiting — the
            wait is evidence, and it must not hide a genuine failure. A platform
            that never converges still fails, with the same summary as before. *)
         let readiness_deadline_s =
           (* The default is generous because a fresh install's controllers need
              minutes, not seconds. Overridable so a harness can bound the wait
              rather than wait it out: a test that asserts the failing end of this
              behaviour must not itself take fifteen minutes. *)
           match Sys.getenv_opt "SOL_PLATFORM_READINESS_TIMEOUT_S" with
           | Some raw ->
             (match float_of_string_opt raw with
              | Some seconds when seconds >= 0. -> seconds
              | _ -> 900.)
           | None -> 900.
         in
         let readiness_poll_s = 15. in
         let deadline = Unix.gettimeofday () +. readiness_deadline_s in
         let waiting_since = Unix.gettimeofday () in
         let rec await_readiness () =
           let checks = sample_readiness () in
           let unmet = unmet_count checks in
           if unmet = 0
           then checks
           else if Unix.gettimeofday () >= deadline
           then checks
           else (
             Printf.printf
               "  awaiting platform readiness: %d check(s) unmet, %.0fs elapsed\n%!"
               unmet
               (Unix.gettimeofday () -. waiting_since);
             Unix.sleepf readiness_poll_s;
             await_readiness ())
         in
         let readiness = await_readiness () in
         let summary = Sol_cli_cloud_lifecycle.readiness_summary readiness in
         if summary <> "Ready"
         then (
           cleanup_bootstrap_access ();
           lifecycle_error ("platform readiness " ^ summary));
         (* ADR 0003 invariant 5: the run may only leave its phase along an edge
            the transition relation admits. PlatformInstalling -> Ready and
            PlatformUpdating -> Ready are both legal, so the exit is checked
            against the phase this run actually entered rather than assumed. *)
         require_terraform_success (deescalate ());
         (* DEC-040: [Ready] is a claim of least privilege, so it is not announced
            until the effective authorization surface shows the bootstrap capability
            is gone. The previous order announced [Ready] and then de-escalated, which
            made the claim before its evidence existed. *)
         (* DEC-040 applies to the AWS bootstrap access, which Sol revokes itself.
            GCP's window lives in the platform root and is closed by applying that
            root, so there is no Sol-side revocation here to verify. *)
         (match outputs with
          | Sol_cli_cloud_lifecycle.Aws_outputs aws_outputs ->
            (match target_cfg.provisioner_role_arn with
             | Some provisioner_role_arn ->
               verify_deescalation
                 ~region:target_cfg.region
                 ~outputs:aws_outputs
                 ~before:
                   (match bootstrap_window_control with
                    | Some (_, probes) -> probes
                    | None -> [])
                 ~provisioner_role_arn
             | None ->
               (* The bootstrap elevation is scoped to the provisioner role; a target
                  that declares none had nothing elevated. Said out loud rather than
                  skipped, because a silently skipped verification is exactly the
                  false-pass shape DEC-040 exists to remove. *)
               Printf.printf
                 "  no provisioner role declared: no bootstrap elevation to verify\n%!")
          | Sol_cli_cloud_lifecycle.Gcp_outputs _ -> ());
         (match
            Sol_cli_cloud_lifecycle.enter
              ~from:operation_phase
              ~to_:Sol_cli_cloud_lifecycle.Ready
          with
          | Ok _ -> ()
          | Error message -> lifecycle_error message);
         (* GCP's window lives in the platform root, so it is closed by applying the
            root that owns the object rather than by a Sol-side revocation step:
            the authority model stays in the layer that defines the authority. *)
         if not (provisioner_rbac_established env)
         then
           lifecycle_error
             "platform provisioner RBAC is not effective after bootstrap access removal";
         (* ADR 0003 / INFRA-031: the run is in [Ready] only once readiness has
            been verified *and* the temporary privileged association has been
            revoked *and* the bounded provisioner has been verified effective —
            all three above. Report it here rather than at the transition check,
            so the phase an operator sees is the state the target is actually
            left in. *)
         Printf.printf
           "  lifecycle phase: %s\n%!"
           (Sol_cli_cloud_lifecycle.phase_to_string Sol_cli_cloud_lifecycle.Ready));
    Printf.printf "\nProvisioned endpoints:\n%!";
    print_outputs infra_dir;
    Printf.printf "\nDone.\n%!"
;;

let cloud_destroy ~target ~var_file ~vars ~action () =
  check_terraform ();
  let provider = provider_of_target_path target in
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
  (* DEC-033: what this destroy deliberately keeps, named by the target. Absent
     means the production default -- retain the final snapshot -- so a
     qualification target opting out never changes what destroy promises by
     default. *)
  let retention =
    match target_cfg.destroy_retention with
    | None -> Sol_cli_cloud_lifecycle.default_destroy_retention
    | Some raw ->
      (match Sol_cli_cloud_lifecycle.destroy_retention_of_string raw with
       | Ok retention -> retention
       | Error message -> lifecycle_error message)
  in
  let cloud_target =
    match Sol_cli_cloud_lifecycle.cloud_target target_cfg with
    | Ok target -> target
    | Error message -> lifecycle_error message
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let var_files =
    match var_file with
    | None -> []
    | Some f -> [ normalize_var_file f ]
  in
  Printf.printf "\nDestroying cloud infrastructure (%s)...\n%!" pname;
  (* The command edge: the destroy sequence itself lives in
     [Sol_cli_cloud_destroy.execute], which never exits; this function resolves
     the request (user input) and turns the typed outcome into a process exit.
     REFAC-091 / HARDEN-004 step 2. *)
  match action with
  | Plan ->
    (* A read-only preview. B / FND-0044 point 2 applies here too: unusable
       install outputs defer the *wiring*, they do not decide that the substrate
       is absent. *)
    let preview () : (unit, string) result =
      let* () =
        match cloud_outputs_of provider infra_dir with
        | Ok (Some outputs) ->
          let platform_dir = platform_dir provider in
          let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
          let* platform_vars =
            platform_vars_of_result
              ~context:Sol_cli_cloud_lifecycle.Destruction
              ~cloud_target
              ~outputs
              ()
          in
          with_cluster_access_result ~region:target_cfg.region outputs (fun ~env ->
            let* () = run_terraform_init_result run_log platform_dir platform_backend in
            terraform_outcome
              (Sol_cli_run_log.run_phase run_log ~name:"platform-plan-destroy" (fun () ->
                 Sol_cli_terraform.plan_destroy
                   ~env
                   ~chdir:platform_dir
                   ~var_files:[]
                   ~vars:platform_vars
                   ())))
        | Ok None ->
          Printf.printf
            "  Platform destroy DEFERRED — no install outputs are published, so the \
             platform teardown cannot be wired.\n\
             %!";
          Ok ()
        | Error reason ->
          Printf.printf
            "  Platform destroy DEFERRED — install outputs are unavailable (%s), so the \
             platform teardown cannot be wired.\n\
             %!"
            reason;
          Ok ()
      in
      let* () =
        terraform_outcome
          (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan-destroy" (fun () ->
             Sol_cli_terraform.plan_destroy ~chdir:infra_dir ~var_files ~vars ()))
      in
      Printf.printf "\nDone. Re-run with --apply to destroy cloud resources.\n%!";
      Ok ()
    in
    (match preview () with
     | Ok () -> ()
     | Error message ->
       Printf.eprintf "error: %s\n%!" message;
       exit 1)
  | Apply ->
    (* The one state observation, captured at the edge so the policy vars the
       edge computes can use it; the library classifies it and owns the
       decisions. Substrate existence comes from this inventory, never from the
       install-time outputs contract (B / FND-0044 point 2). *)
    let state_ref = ref Sol_cli_cloud_destroy.State_empty in
    let prepared_ref = ref Sol_cli_cloud_destroy.Nothing_prepared in
    let outputs_ref = ref None in
    let before_ref = ref None in
    let destroy_phase () =
      let substrate = Sol_cli_cloud_destroy.substrate_presence !state_ref in
      let cloud_exists = substrate <> Sol_cli_cloud_destroy.Substrate_absent in
      Sol_cli_cloud_lifecycle.enter_destruction
        ~from:
          (Sol_cli_cloud_lifecycle.observed_phase ~cloud_exists ~platform_installed:true)
    in
    (* ADR 0003 / HARDEN-002 run 4 finding 15: from [Preparing_destroy] on, the
       Destroy policy governs the desired state. Its overrides are appended AFTER
       `vars`, so the Production/Ready invariant terraform_vars injects
       (rds_deletion_protection=true -- BUG-039, still correct in Ready) cannot be
       restored by the bootstrap-admin reconciliation that necessarily precedes
       the destroy. *)
    let destroy_apply_vars () =
      vars
      @ Sol_cli_terraform.kv_args
          (destroy_policy_vars
             ~provider
             ~phase:(destroy_phase ())
             ~retention
             ~prepared:!prepared_ref)
    in
    (* The cluster name the RDS final-snapshot identity is derived from: the
       install outputs when they are usable, otherwise the target's own
       declaration, so a half-built output-less target is still preparable (B). *)
    let prepare_cluster_name () =
      match !outputs_ref with
      | Some outputs -> Sol_cli_cloud_lifecycle.cluster_name outputs
      | None ->
        (match resolved_var "cluster_name" ~var_files ~vars ~default:None with
         | Some name -> name
         | None -> workspace_name ())
    in
    (* The platform teardown, result-returning. The elevated bootstrap access is
       opened by the bracket ([reconcile_and_enable]) and removed by its cleanup,
       so this never threads an [on_error]: a failure returns, and the removal
       happens structurally (FND-0047). *)
    let destroy_platform_result ~outputs () : (unit, string) result =
      let platform_dir = platform_dir provider in
      let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
      let* platform_vars =
        platform_vars_of_result
          ~context:Sol_cli_cloud_lifecycle.Destruction
          ~cloud_target
          ~outputs
          ()
      in
      with_cluster_access_result ~region:target_cfg.region outputs (fun ~env ->
        let* () = run_terraform_init_result run_log platform_dir platform_backend in
        let destroy_once () =
          Sol_cli_terraform.destroy
            ~env
            ~chdir:platform_dir
            ~var_files:[]
            ~vars:platform_vars
            ()
        in
        let destroy =
          Sol_cli_run_log.run_phase run_log ~name:"platform-destroy" destroy_once
        in
        let verify_absent () =
          if not (platform_absent env)
          then Error "platform absence verification failed after destroy"
          else Ok ()
        in
        match destroy with
        | Ok result when result.Sol_cli_process.exit_code = 0 -> verify_absent ()
        | _ ->
          (* INFRA-042. Terraform's destroy has been attempted first, in full, with
             its own ordering and ownership -- this is recovery, not a different
             strategy. Only resources whose kind the cluster demonstrably does not
             serve are forgotten, and each one is named. If nothing qualifies, the
             original failure stands. *)
          (match served_api_kinds env with
           | Error message ->
             Printf.eprintf
               "error: the platform destroy failed, and the recovery step could not \
                determine which kinds the cluster serves: %s\n\
                %!"
               message;
             terraform_outcome destroy
           | Ok served ->
             (match unserved_manifest_resources ~served ~chdir:platform_dir with
              | Error message ->
                Printf.eprintf
                  "error: the platform destroy failed, and the recovery step could not \
                   read the platform state: %s\n\
                   %!"
                  message;
                terraform_outcome destroy
              | Ok [] -> terraform_outcome destroy
              | Ok unserved ->
                Printf.printf
                  "\n\
                  \  platform destroy could not delete %d resource(s) whose kind this \
                   cluster does not serve, so they cannot exist;\n\
                  \  forgetting them in state (the objects, not the objects' absence, is \
                   what Terraform cannot address):\n\
                   %!"
                  (List.length unserved);
                let* () =
                  List.fold_left
                    (fun acc (address, kind) ->
                       let* () = acc in
                       Printf.printf
                         "    %s (%s is not served by this cluster)\n%!"
                         address
                         kind;
                       terraform_outcome
                         (Sol_cli_run_log.run_phase
                            run_log
                            ~name:"platform-destroy-forget-unserved"
                            (fun () ->
                               Sol_cli_terraform.state_rm
                                 ~env
                                 ~chdir:platform_dir
                                 ~address
                                 ())))
                    (Ok ())
                    unserved
                in
                (* Once, and then the failure is the failure. A second pass that also
                   fails means something is genuinely undeletable, which is the case
                   this recovery must not paper over. *)
                let retry =
                  Sol_cli_run_log.run_phase
                    run_log
                    ~name:"platform-destroy-retry"
                    destroy_once
                in
                (match retry with
                 | Ok result when result.Sol_cli_process.exit_code = 0 -> verify_absent ()
                 | _ -> terraform_outcome retry))))
    in
    let deps : Sol_cli_cloud_destroy.deps =
      { require_credentials =
          (* INFRA-039: credentials are resolved again here, per mutating stage,
             rather than assumed from process start -- a platform stage runs many
             minutes after the cloud stage. *)
          (fun () ->
            credentials_result
              ~provider
              ~operation:"destroying"
              ~leaves_target_standing:true)
      ; terraform_init =
          (fun () -> run_terraform_init_result run_log infra_dir cloud_backend)
      ; observe_state =
          (fun () ->
            match Sol_cli_terraform.show_json ~chdir:infra_dir () with
            | Ok result when result.Sol_cli_process.exit_code = 0 ->
              state_ref := Sol_cli_cloud_destroy.inventory_of_show_json result.stdout;
              Ok result.stdout
            | Ok result ->
              Error (Printf.sprintf "terraform show failed with exit %d" result.exit_code)
            | Error error ->
              Error
                ("could not read terraform state: "
                 ^ Sol_cli_process.error_to_string error))
      ; cloud_outputs =
          (fun () ->
            match cloud_outputs_of provider infra_dir with
            | Ok (Some outputs) ->
              outputs_ref := Some outputs;
              Sol_cli_cloud_destroy.Outputs_available
            | Ok None ->
              Sol_cli_cloud_destroy.Outputs_unavailable "no install outputs are published"
            | Error reason -> Sol_cli_cloud_destroy.Outputs_unavailable reason)
      ; prepare =
          (fun ~state ->
            let* preparation =
              prepare_destruction_result
                ~provider
                run_log
                infra_dir
                var_files
                vars
                ~cluster_name:(prepare_cluster_name ())
                ~retention
                ~state
            in
            prepared_ref := preparation;
            Ok preparation)
      ; reconcile_and_enable =
          (fun () ->
            (* Scope is bootstrap + the guarded resources the inventory represents,
               and the plan is asserted: a missing cluster the `-target` pulls in
               plans a create and is refused (HARDEN-004 step 3). *)
            let guarded = guarded_addresses_of provider !state_ref in
            apply_asserted
              ~run_log
              ~phase_name:"destroy-reconciliation-apply"
              ~policy:
                (Sol_cli_cloud_destroy.reconciliation_policy
                   ~bootstrap:(bootstrap_matchers provider)
                   ~guarded)
              ~scope:(reconciliation_scope provider guarded)
              ~chdir:infra_dir
              ~var_files
              ~vars:
                (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:true)
                 @ destroy_apply_vars ())
              ())
      ; destroy_platform =
          (fun () ->
            match !outputs_ref with
            | Some outputs -> destroy_platform_result ~outputs ()
            | None ->
              Error
                "the platform teardown requires install outputs, which are unavailable")
      ; remove_elevated_access =
          (fun () ->
            (* The removal is asserted like any other apply: "cleanup" is a name,
               not a safety property. If its plan is not permitted, the apply does
               not run and the outcome records that the access may remain --
               [with_elevated_access] carries the cleanup failure as evidence. *)
            apply_asserted
              ~run_log
              ~phase_name:"provisioner-bootstrap-access-remove"
              ~policy:
                (Sol_cli_cloud_destroy.bootstrap_removal_policy
                   ~bootstrap:(bootstrap_matchers provider))
              ~scope:(bootstrap_scope provider)
              ~chdir:infra_dir
              ~var_files
              ~vars:
                (vars @ Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:false))
              ())
      ; observe_window_before =
          (fun () ->
            (* DEC-040 acceptance: the destroy path revokes the same bootstrap access
               the install path does, so it owes the same evidence. The observation
               is best-effort: a probe that can fail must not block teardown (ADR
               0003 invariant 6). It runs while this run's window is open; the
               verification runs after the removal, through the bracket. *)
            let deescalation_target =
              match provider, target_cfg.provisioner_role_arn, !outputs_ref with
              | ( Sol_cli_provider.Aws
                , Some provisioner_role_arn
                , Some (Sol_cli_cloud_lifecycle.Aws_outputs aws_outputs) ) ->
                Some (provisioner_role_arn, aws_outputs)
              | _ -> None
            in
            match deescalation_target with
            | None ->
              (* A target that declares no provisioner role elevated nothing; said out
                 loud rather than skipped, the same as on the install path. *)
              (match provider with
               | Sol_cli_provider.Aws ->
                 Printf.printf
                   "  no provisioner role declared: no bootstrap elevation to verify\n%!"
               | Sol_cli_provider.Gcp -> ());
              Ok ()
            | Some (provisioner_role_arn, aws_outputs) ->
              (match
                 observe_bootstrap_window_result
                   ~region:target_cfg.region
                   ~outputs:aws_outputs
                   ~provisioner_role_arn
                   ()
               with
               | Ok (_, probes) ->
                 before_ref := Some (provisioner_role_arn, aws_outputs, probes);
                 Ok ()
               | Error message -> Error message))
      ; verify_window_after =
          (fun () ->
            match !before_ref with
            | None -> Ok ()
            | Some (provisioner_role_arn, aws_outputs, before) ->
              (match
                 await_deescalation
                   ~region:target_cfg.region
                   ~outputs:aws_outputs
                   ~before
                   ~provisioner_role_arn
               with
               | Sol_cli_cloud_lifecycle.Deescalated -> Ok ()
               | verdict ->
                 Error
                   (Printf.sprintf
                      "the bootstrap access was removed but its effective removal could \
                       not be verified (%s). Proceeding: destroying the substrate \
                       removes the access with it, and teardown is not blocked by a \
                       probe that can fail (ADR 0003 invariant 6)."
                      (Sol_cli_cloud_lifecycle.deescalation_verdict_to_string verdict))))
      ; destroy_substrate =
          (fun () ->
            (* The AWS load-balancer drain wait is provider glue that must run before
               the substrate destroy that needs it; it is a no-op on GCP. *)
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
            terraform_outcome
              (Sol_cli_run_log.run_phase run_log ~name:"terraform-destroy" (fun () ->
                 Sol_cli_terraform.destroy
                   ~chdir:infra_dir
                   ~var_files
                   ~vars:(destroy_apply_vars ())
                   ())))
      ; verify_absent =
          (fun () ->
            match provider with
            | Sol_cli_provider.Aws -> verify_aws_destroy ~var_files ~vars
            | Sol_cli_provider.Gcp -> verify_gcp_destroy ~var_files ~vars)
      ; report = (fun message -> Printf.printf "%s\n%!" message)
      ; warn = (fun message -> Printf.eprintf "%s\n%!" message)
      }
    in
    (* One place maps the typed outcome to a process exit. *)
    (match Sol_cli_cloud_destroy.execute ~deps with
     | Sol_cli_cloud_destroy.Destroy_succeeded { preparation; cleanup; _ } ->
       (match cleanup with
        | Sol_cli_cloud_destroy.Cleanup_failed message ->
          Printf.eprintf
            "warning: removing the bootstrap access failed (%s); the elevated access may \
             still be applied\n\
             %!"
            message
        | Sol_cli_cloud_destroy.Cleanup_not_needed
        | Sol_cli_cloud_destroy.Cleanup_succeeded -> ());
       (* DEC-033: the destroy states what it kept, by identifier, so an operator
          never has to infer it from the absence of a snapshot listing. *)
       (match preparation with
        | Sol_cli_cloud_destroy.Aws_prepared snapshot_id ->
          Printf.printf
            "\n%s\n%!"
            (Sol_cli_cloud_lifecycle.retention_report
               ~retention
               ~destroy_snapshot_id:snapshot_id)
        | Sol_cli_cloud_destroy.Gcp_prepared ->
          Printf.printf
            "\n%s\n%!"
            (Sol_cli_cloud_lifecycle.retention_report ~retention ~destroy_snapshot_id:"")
        | Sol_cli_cloud_destroy.Nothing_prepared ->
          Printf.printf
            "\n\
            \  retention: nothing to decide -- this target had no database whose \
             retention a destroy had to settle\n\
             %!");
       Printf.printf "\nDone.\n%!"
     | Sol_cli_cloud_destroy.Destroy_failed { failure; cleanup } ->
       (* A cleanup failure is evidence, not silence: it is reported alongside the
          failure that stopped the run, never replaced by it. *)
       (match cleanup with
        | Sol_cli_cloud_destroy.Cleanup_failed message ->
          Printf.eprintf
            "warning: removing the bootstrap access failed (%s); the elevated access may \
             still be applied\n\
             %!"
            message
        | Sol_cli_cloud_destroy.Cleanup_not_needed
        | Sol_cli_cloud_destroy.Cleanup_succeeded -> ());
       Printf.eprintf "error: %s\n%!" (Sol_cli_cloud_destroy.failure_message failure);
       exit 1)
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

let confirm_ecr_removal_flag =
  Arg.(
    value
    & flag
    & info
        [ "confirm-ecr-removal" ]
        ~doc:
          "Allow an apply whose plan deletes ECR repositories (and every image in them). \
           Without it such an apply is refused before anything changes.")
;;

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
      const (fun target var_file vars confirm_ecr_removal ->
        cloud_init ~confirm_ecr_removal ~target ~var_file ~vars ~action:Apply ())
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ confirm_ecr_removal_flag)
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
