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
    let eips_gone = aws_no_elastic_ips ~region ~cluster_name in
    let nat_gone = aws_no_nat_gateways ~region ~cluster_name in
    let ebs_gone = aws_no_ebs_volumes ~region ~cluster_name in
    if
      not
        (eks_gone && rds_gone && ecr_gone && elb_gone && eips_gone && nat_gone && ebs_gone)
    then exit 1;
    Printf.printf
      "  AWS verification passed: \
       EKS/RDS/ECR/load-balancers/EIPs/NAT-gateways/EBS-volumes not found.\n\
       %!"
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
let verify_gcp_destroy ~var_files ~vars =
  let project =
    match resolved_var "project_id" ~var_files ~vars ~default:None with
    | Some project -> project
    | None ->
      Printf.eprintf "error: cannot verify GCP destroy without project_id.\n";
      Printf.eprintf "  Pass the same --var project_id=... or --var-file used for init.\n";
      exit 1
  in
  let cluster_name =
    match resolved_var "cluster_name" ~var_files ~vars ~default:None with
    | Some cluster_name -> cluster_name
    | None ->
      Printf.eprintf "error: cannot verify GCP destroy without cluster_name.\n";
      Printf.eprintf
        "  Pass the same --var cluster_name=... or --var-file used for init.\n";
      exit 1
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
  then exit 1;
  Printf.printf
    "  GCP verification passed: GKE/Cloud SQL/network/registry/peering-address not \
     found, and no service-networking peering remains.\n\
     %!"
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
let platform_vars_of ?(on_error = Fun.id) ~cloud_target ~outputs () =
  match Sol_cli_cloud_lifecycle.platform_inputs cloud_target outputs with
  | Error message ->
    on_error ();
    lifecycle_error message
  | Ok inputs ->
    (match Sol_cli_cloud_lifecycle.platform_terraform_vars inputs with
     | Ok vars -> vars
     | Error message ->
       on_error ();
       lifecycle_error message)
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
           ; Sol_cli_cloud_lifecycle.cluster_access_role_arn outputs
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

(* DEC-040 / FND-0021: de-escalation is not complete because a control plane said so.

   Live, an EKS access-policy disassociation was accepted, `describe-access-entry`
   reported no access policies, and the authorizer went on granting cluster-admin for
   over five minutes. A successful apply that removes the bootstrap access entry is the
   same kind of evidence, so the phase asks the component that actually enforces the
   boundary instead: the capabilities only the bootstrap authority held, probed as the
   steady-state platform identity through the same ephemeral access the platform uses.
   Anything still permitted means the elevated capability is still usable, whatever the
   API reports. *)
let bootstrap_only_capabilities =
  [ "create", "clusterroles"
  ; "create", "clusterrolebindings"
  ; "escalate", "clusterroles"
  ]
;;

let deescalation_probes ~region ~outputs () =
  with_provisioner_kubeconfig ~region outputs (fun env ->
    List.map
      (fun (verb, resource) ->
         let permitted =
           match
             Sol_cli_process.run
               (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "can-i"; verb; resource ])
           with
           | Ok r -> r.Sol_cli_process.exit_code = 0
           | Error _ -> false
         in
         Printf.sprintf "%s %s" verb resource, permitted)
      bootstrap_only_capabilities)
;;

(* Bounded and fail-closed: access-entry changes are eventually consistent so a retry
   is expected, but an unverified claim is not an acceptable outcome. *)
let verify_deescalation ~region ~outputs =
  let interval_s = 10. in
  let rec loop remaining =
    let verdict =
      Sol_cli_cloud_lifecycle.deescalation_verdict
        (deescalation_probes ~region ~outputs ())
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
  match loop 6 with
  | Sol_cli_cloud_lifecycle.Deescalated ->
    Printf.printf
      "  de-escalation verified against the effective authorization surface\n%!"
  | verdict ->
    lifecycle_error
      ("de-escalation could not be established: "
       ^ Sol_cli_cloud_lifecycle.deescalation_verdict_to_string verdict)
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
let require_gcp_platform_toolchain () =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "gke-gcloud-auth-plugin"; "--version" ])
  with
  | Ok result when result.Sol_cli_process.exit_code = 0 -> ()
  | _ ->
    lifecycle_error
      "the platform cannot reach a GKE cluster without `gke-gcloud-auth-plugin`, which \
       is not on PATH: the kubeconfig gcloud writes names it as its credential plugin, \
       so every Kubernetes call would fail with \"executable gke-gcloud-auth-plugin not \
       found\". Install it (`gcloud components install gke-gcloud-auth-plugin`) and \
       re-run. Nothing has been changed."
;;

let gcp_provisioner_kubeconfig ~region outputs f =
  require_gcp_platform_toolchain ();
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
    | Ok result when result.exit_code = 0 -> f env
    | Ok result ->
      (* Attempt 2 also showed why this failed without saying so. The message named
         the step and nothing else, so the reason -- a missing impersonation grant
         versus a wrong flag -- had to be reconstructed by hand. *)
      lifecycle_error
        (Printf.sprintf
           "could not establish ephemeral cluster access as %s: gcloud exited %d%s"
           outputs.Sol_cli_cloud_lifecycle.provisioner_service_account
           result.Sol_cli_process.exit_code
           (let detail = String.trim result.Sol_cli_process.stderr in
            if detail = "" then "" else ":\n" ^ detail))
    | Error error ->
      lifecycle_error
        (Printf.sprintf
           "could not run gcloud to establish cluster access: %s"
           (Sol_cli_process.error_to_string error)))
;;

let with_cluster_access ?(on_error = Fun.id) ~region outputs f =
  match outputs with
  | Sol_cli_cloud_lifecycle.Aws_outputs outputs ->
    with_provisioner_kubeconfig ~on_error ~region outputs f
  | Sol_cli_cloud_lifecycle.Gcp_outputs outputs ->
    ignore on_error;
    gcp_provisioner_kubeconfig ~region outputs f
;;

(* INFRA-039 resolved credentials per mutating stage, because a platform stage runs
   many minutes after the cloud stage and a run can lose its session in between.
   GCP's credential is Application Default Credentials and the reasoning is
   identical -- including the part that matters most: a destroy that cannot
   authenticate leaves billable infrastructure standing *and* disables the only
   supported path to remove it. So the same guarantee is made through the
   provider's own mechanism rather than assumed on GCP because it was implemented
   on AWS. The token itself is never printed. *)
let require_credentials ~provider ~operation ~leaves_target_standing =
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
       lifecycle_error
         (Sol_cli_credentials.unresolved_message
            ~operation
            ~profile
            ~leaves_target_standing
            ~detail)
     | Ok credentials ->
       Sol_cli_credentials.install credentials;
       Printf.printf "  credentials: %s\n%!" credentials.principal)
  | Sol_cli_provider.Gcp ->
    (match
       process_output [ "gcloud"; "auth"; "application-default"; "print-access-token" ]
     with
     | Some _ ->
       Printf.printf "  credentials: Google Application Default Credentials resolved\n%!"
     | None ->
       lifecycle_error
         (Printf.sprintf
            "cannot resolve Google Application Default Credentials, so Sol cannot \
             %s              this target.%s Run `gcloud auth application-default login` \
             (or fix the              attached service account) and re-run."
            operation
            standing_remark))
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
           | `String s when s <> "" -> Some s
           | _ -> None
         in
         (* DEC-033: whether a final snapshot will be taken is decided by
            [skip_final_snapshot], not by the presence of an identifier. An empty
            identifier alone cannot distinguish "keeps nothing" from "keeps the
            cluster-name default", so the verification reads the setting itself. *)
         let skip_final_snapshot =
           match v |> member "skip_final_snapshot" with
           | `Bool b -> Some b
           | _ -> None
         in
         Ok (Some (deletion_protection, final_snapshot_identifier, skip_final_snapshot))
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
let prepare_destroy run_log infra_dir var_files vars ~cluster_name ~retention =
  match rds_state infra_dir with
  | Error message -> lifecycle_error message
  | Ok None ->
    Printf.printf "  prepare: no RDS instance for this target, nothing to prepare.\n%!";
    None
  | Ok (Some _) ->
    let snapshot_id = unique_rds_snapshot_id cluster_name in
    Printf.printf
      "  prepare: disabling RDS deletion protection%s...\n%!"
      (match retention with
       | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
         ", final snapshot " ^ snapshot_id
       | Sol_cli_cloud_lifecycle.Retain_nothing -> ", retaining nothing");
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"rds-destroy-prepare" (fun () ->
         Sol_cli_terraform.apply
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
              | Sol_cli_cloud_lifecycle.Retain_nothing ->
                [ "rds_skip_final_snapshot=true" ])
           ()));
    Some snapshot_id
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
let verify_destroy_preparation infra_dir ~retention ~prepared =
  match prepared with
  | None -> Printf.printf "  verify preparation: nothing was prepared.\n%!"
  | Some snapshot_id ->
    (match rds_state infra_dir with
     | Error message -> lifecycle_error message
     | Ok None ->
       lifecycle_error
         "RDS destroy preparation ran but the instance is now absent from state"
     | Ok (Some (deletion_protection, final_snapshot_identifier, skip_final_snapshot)) ->
       if deletion_protection
       then lifecycle_error "RDS deletion protection is still enabled after preparation";
       (match retention with
        | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
          (match skip_final_snapshot with
           | Some true ->
             lifecycle_error
               "the target retains its final snapshot, but preparation disabled snapshot \
                creation"
           | None ->
             lifecycle_error
               "cannot establish that the final snapshot will be retained: \
                skip_final_snapshot is absent from state"
           | Some false -> ());
          if final_snapshot_identifier <> Some snapshot_id
          then
            lifecycle_error
              (Printf.sprintf
                 "RDS final snapshot identifier is %s, expected the prepared %s"
                 (Option.value final_snapshot_identifier ~default:"<none>")
                 snapshot_id)
        | Sol_cli_cloud_lifecycle.Retain_nothing ->
          (match skip_final_snapshot with
           | Some true -> ()
           | Some false ->
             lifecycle_error
               "the target retains nothing, but preparation left snapshot creation \
                enabled"
           | None ->
             lifecycle_error
               "cannot establish that snapshot creation is disabled: skip_final_snapshot \
                is absent from state"));
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
         (Sol_cli_cloud_lifecycle.destroy_retention_to_string retention))
;;

(* The GCP counterpart of [rds_state]: what the target's guarded resources
   currently declare, read from the root's own state for the same reason -- the
   question preparation answers is "did the change actually land", which is a claim
   about this root's state rather than about the provider's API.

   Two resources carry a deletion guard on GCP, by two different mechanisms: Cloud
   SQL's is the provider's attribute *and* an API-level setting, and the GKE
   cluster's is the provider's own attribute, which defaults to true. Live attempt
   1 found the second only after Cloud SQL had been lifted -- the teardown then
   refused with "Cannot destroy cluster because deletion_protection is set to
   true", so a target Sol had provisioned could not be destroyed through Sol at
   all. Both are read, and both are lifted. *)
let gcp_protection_state infra_dir =
  match Sol_cli_terraform.show_json ~chdir:infra_dir () with
  | Ok result when result.Sol_cli_process.exit_code = 0 ->
    (try
       let open Yojson.Safe.Util in
       let resources =
         Yojson.Safe.from_string result.stdout
         |> member "values"
         |> member "root_module"
         |> member "resources"
         |> to_list
       in
       let guard resource_type =
         resources
         |> List.find_opt (fun r -> member "type" r = `String resource_type)
         |> Option.map (fun r ->
           member "values" r |> member "deletion_protection" |> to_bool)
       in
       Ok (guard "google_sql_database_instance", guard "google_container_cluster")
     with
     | Yojson.Json_error message -> Error ("invalid `terraform show -json`: " ^ message)
     | Yojson.Safe.Util.Type_error (message, _) ->
       Error ("unexpected `terraform show -json` shape: " ^ message))
  | Ok result ->
    Error (Printf.sprintf "terraform show failed with exit %d" result.exit_code)
  | Error _ -> Error "could not read terraform state"
;;

let gcp_guarded_targets =
  Sol_cli_terraform.targets
    "google_sql_database_instance.postgres"
    [ "google_container_cluster.main" ]
;;

(* Deletion protection is not retention, and the distinction is the whole point of
   DEC-033: this transition makes the target *destructible*, it does not decide what
   survives. Both of GCP's guards are Terraform/provider attributes, and a destroy
   plan carries only deletes, so the provider is handed prior state and a `-var` on
   the destroy never reaches it -- lifting them is therefore its own targeted applied
   transition, verified from state afterwards rather than assumed. Doing nothing here
   does not skip a preparation, it makes the destroy impossible and the target
   billable. *)
let gcp_prepare_destroy run_log infra_dir var_files vars =
  match gcp_protection_state infra_dir with
  | Error message -> lifecycle_error message
  | Ok (None, None) ->
    Printf.printf
      "  prepare: no guarded resource for this target, nothing to prepare.\n%!";
    false
  | Ok _ ->
    Printf.printf "  prepare: disabling the Cloud SQL and GKE deletion guards...\n%!";
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"gcp-destroy-prepare" (fun () ->
         Sol_cli_terraform.apply
           ~scope:gcp_guarded_targets
           ~chdir:infra_dir
           ~var_files
           ~vars:
             (vars @ [ "sql_deletion_protection=false"; "gke_deletion_protection=false" ])
           ()));
    true
;;

let verify_gcp_destroy_preparation infra_dir ~prepared =
  if not prepared
  then Printf.printf "  verify preparation: nothing was prepared.\n%!"
  else (
    match gcp_protection_state infra_dir with
    | Error message -> lifecycle_error message
    | Ok (None, None) ->
      lifecycle_error "GCP destroy preparation ran but no guarded resource is in state"
    | Ok (sql, cluster) ->
      (match sql with
       | Some true ->
         lifecycle_error
           "Cloud SQL deletion protection is still enabled after preparation"
       | _ -> ());
      (match cluster with
       | Some true ->
         lifecycle_error "GKE deletion protection is still enabled after preparation"
       | _ -> ());
      Printf.printf
        "  verify preparation: Cloud SQL and GKE deletion protection disabled.\n%!")
;;

(* What destruction preparation did. The providers differ in what there is to carry
   forward -- AWS's prepared final-snapshot identity has no GCP counterpart, because
   Cloud SQL destroys its backups with the instance -- so the difference is named in
   the type rather than flattened into an option that would have to mean two
   things. *)
type destruction_preparation =
  | Nothing_prepared
  | Aws_prepared of string
  | Gcp_prepared

let prepare_destruction
      ~provider
      run_log
      infra_dir
      var_files
      vars
      ~cluster_name
      ~retention
  =
  match provider with
  | Sol_cli_provider.Aws ->
    let prepared =
      prepare_destroy run_log infra_dir var_files vars ~cluster_name ~retention
    in
    verify_destroy_preparation infra_dir ~retention ~prepared;
    (match prepared with
     | None -> Nothing_prepared
     | Some snapshot_id -> Aws_prepared snapshot_id)
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
       lifecycle_error
         "this GCP target's destroy_retention is final-snapshot (the default), but Sol \
          cannot retain anything on GCP yet: Cloud SQL deletes its backups together with \
          the instance, so there is no final-artifact equivalent of the RDS snapshot and \
          the recovery data would be discarded without saying so. Declare \
          `destroy_retention: none` on a disposable target, or export the database first \
          -- Sol will not decide this for you"
     | Sol_cli_cloud_lifecycle.Retain_nothing ->
       let prepared = gcp_prepare_destroy run_log infra_dir var_files vars in
       verify_gcp_destroy_preparation infra_dir ~prepared;
       if prepared then Gcp_prepared else Nothing_prepared)
;;

(* The Destroy policy's overrides for this provider, given what preparation found.
   Appended after the caller's own variables so the phase policy wins (ADR 0003 /
   HARDEN-002 finding 15). *)
let destroy_policy_vars ~provider ~phase ~retention ~prepared =
  match prepared with
  | Nothing_prepared -> []
  | Aws_prepared snapshot_id ->
    Sol_cli_cloud_lifecycle.policy_vars
      ~provider
      ~phase
      ~destroy_snapshot_id:snapshot_id
      ~retention
  | Gcp_prepared ->
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

let cloud_init ~target ~var_file ~vars ~action () =
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
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-apply" (fun () ->
         Sol_cli_terraform.apply
           ~scope:Sol_cli_terraform.whole_root
           ~chdir:infra_dir
           ~var_files
           ~vars:(Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:true) @ vars)
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
             ~vars:
               (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:false) @ vars)
             ())
    in
    let cleanup_bootstrap_access () = ignore (deescalate ()) in
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
            verify_deescalation ~region:target_cfg.region ~outputs:aws_outputs
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
  (* INFRA-039: credentials are resolved again here, per mutating stage,
       rather than assumed from process start -- a platform stage runs many
       minutes after the cloud stage. *)
  (match action with
   | Plan -> ()
   | _ ->
     require_credentials ~provider ~operation:"destroying" ~leaves_target_standing:true);
  run_terraform_init run_log infra_dir cloud_backend;
  let outputs =
    match cloud_outputs_of provider infra_dir with
    | Ok outputs -> outputs
    | Error message -> lifecycle_error message
  in
  let destroy_platform ?(on_error = Fun.id) outputs =
    let platform_dir = platform_dir provider in
    let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
    let platform_vars = platform_vars_of ~cloud_target ~outputs () in
    with_cluster_access ~on_error ~region:target_cfg.region outputs (fun env ->
      let init = terraform_init run_log platform_dir platform_backend in
      (match init with
       | Ok result when result.exit_code = 0 -> ()
       | _ ->
         on_error ();
         require_terraform_success init);
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
        then (
          on_error ();
          lifecycle_error "platform absence verification failed after destroy")
      in
      match destroy with
      | Ok result when result.exit_code = 0 -> verify_absent ()
      | _ ->
        (* INFRA-042. Terraform's destroy has been attempted first, in full, with
           its own ordering and ownership -- this is recovery, not a different
           strategy. Only resources whose kind the cluster demonstrably does not
           serve are forgotten, and each one is named. If nothing qualifies, the
           original failure stands. *)
        (match served_api_kinds env with
         | Error message ->
           on_error ();
           Printf.eprintf
             "error: the platform destroy failed, and the recovery step could not \
              determine which kinds the cluster serves: %s\n\
              %!"
             message;
           require_terraform_success destroy
         | Ok served ->
           (match unserved_manifest_resources ~served ~chdir:platform_dir with
            | Error message ->
              on_error ();
              Printf.eprintf
                "error: the platform destroy failed, and the recovery step could not \
                 read the platform state: %s\n\
                 %!"
                message;
              require_terraform_success destroy
            | Ok [] ->
              on_error ();
              require_terraform_success destroy
            | Ok unserved ->
              Printf.printf
                "\n\
                \  platform destroy could not delete %d resource(s) whose kind this \
                 cluster does not serve, so they cannot exist;\n\
                \  forgetting them in state (the objects, not the objects' absence, is \
                 what Terraform cannot address):\n\
                 %!"
                (List.length unserved);
              List.iter
                (fun (address, kind) ->
                   Printf.printf
                     "    %s (%s is not served by this cluster)\n%!"
                     address
                     kind;
                   require_terraform_success
                     (Sol_cli_run_log.run_phase
                        run_log
                        ~name:"platform-destroy-forget-unserved"
                        (fun () ->
                           Sol_cli_terraform.state_rm ~env ~chdir:platform_dir ~address ())))
                unserved;
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
               | Ok result when result.exit_code = 0 -> verify_absent ()
               | _ ->
                 on_error ();
                 require_terraform_success retry))))
  in
  match action with
  | Plan ->
    (match outputs with
     | None ->
       Printf.printf "  Platform destroy DEFERRED — cloud substrate is absent.\n%!"
     | Some outputs ->
       let platform_dir = platform_dir provider in
       let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
       let platform_vars = platform_vars_of ~cloud_target ~outputs () in
       with_cluster_access ~region:target_cfg.region outputs (fun env ->
         (* INFRA-039: credentials are resolved again here, per mutating stage,
       rather than assumed from process start -- a platform stage runs many
       minutes after the cloud stage. *)
         (match action with
          | Plan -> ()
          | _ ->
            require_credentials
              ~provider
              ~operation:"destroying"
              ~leaves_target_standing:true);
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
    let prepared =
      match outputs with
      | None ->
        Printf.printf "  prepare: cloud substrate is absent, nothing to prepare.\n%!";
        Nothing_prepared
      | Some outputs ->
        let cluster_name = Sol_cli_cloud_lifecycle.cluster_name outputs in
        prepare_destruction
          ~provider
          run_log
          infra_dir
          var_files
          vars
          ~cluster_name
          ~retention
    in
    (* ADR 0003 / HARDEN-002 run 4 finding 15: from [Preparing_destroy] on, the
       Destroy policy governs the desired state. Its overrides are appended AFTER
       `vars`, so the Production/Ready invariant terraform_vars injects
       (rds_deletion_protection=true -- BUG-039, still correct in Ready) cannot be
       restored by the bootstrap-admin reconciliation that necessarily precedes
       the destroy. Re-verifying after that apply structurally rejects a
       PreparingDestroy -> Ready-policy regression. *)
    (* ADR 0003 invariant 6 (HARDEN-002 run 5): destruction is an abort edge, not a
       forward transition, so it is available from every phase that can hold
       infrastructure -- including a half-built one. This is the entry that used to
       be faked: the phase was asserted here as [Preparing_destroy] unconditionally,
       which made the model and the operation disagree about whether destroying a
       partially installed target was legal (the forward relation rejects
       `Platform_installing -> Preparing_destroy`).

       Destroy therefore observes the *coarsest* fact that decides the edge --
       whether the substrate exists -- and does not probe the platform: [Ready] and
       [PlatformInstalling] are equally destructible, so the answer is the same,
       while a probe that can fail would be able to block teardown and strand
       exactly the half-built target this invariant protects. *)
    let observed =
      Sol_cli_cloud_lifecycle.observed_phase
        ~cloud_exists:(Option.is_some outputs)
        ~platform_installed:true
    in
    let destroy_phase = Sol_cli_cloud_lifecycle.enter_destruction ~from:observed in
    Printf.printf
      "  lifecycle phase: %s\n%!"
      (Sol_cli_cloud_lifecycle.phase_to_string destroy_phase);
    (* ADR 0003 invariant 4 at the decision point: whatever phase destruction is
       in, the Ready/Production invariant must not be in force. [enter_destruction]
       can only yield [Preparing_destroy] or [Absent], so this now holds by
       construction; it stays as a fail-closed assertion because the cost of being
       wrong here is a stranded RDS instance (finding 15) and the branch is free. *)
    if Sol_cli_cloud_lifecycle.ready_policy_applies destroy_phase
    then lifecycle_error "Ready policy must not apply once destruction has been prepared";
    let destroy_vars =
      Sol_cli_terraform.kv_args
        (destroy_policy_vars ~provider ~phase:destroy_phase ~retention ~prepared)
    in
    let destroy_apply_vars = vars @ destroy_vars in
    (match outputs with
     | None -> ()
     | Some outputs ->
       require_terraform_success
         (Sol_cli_run_log.run_phase
            run_log
            ~name:"destroy-reconciliation-apply"
            (fun () ->
               Sol_cli_terraform.apply
                 ~scope:Sol_cli_terraform.whole_root
                 ~chdir:infra_dir
                 ~var_files
                 ~vars:
                   (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:true)
                    @ destroy_apply_vars)
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
                ~vars:
                  (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:false)
                   @ destroy_apply_vars)
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
    (* ADR 0003 / INFRA-031: this is where the lifecycle actually enters
       [Destroying] — preparation is verified above and the platform is already
       gone, so what remains is tearing the cloud substrate down. An absent
       target never reaches it and reported [Absent] instead, which is why this
       is conditional rather than an unconditional phase claim. *)
    if Option.is_some outputs
    then
      Printf.printf
        "  lifecycle phase: %s\n%!"
        (Sol_cli_cloud_lifecycle.phase_to_string Sol_cli_cloud_lifecycle.Destroying);
    require_terraform_success
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-destroy" (fun () ->
         Sol_cli_terraform.destroy ~chdir:infra_dir ~var_files ~vars:destroy_apply_vars ()));
    Printf.printf "\nVerifying teardown...\n%!";
    (match provider with
     | Sol_cli_provider.Aws -> verify_aws_destroy ~var_files ~vars
     | Sol_cli_provider.Gcp -> verify_gcp_destroy ~var_files ~vars);
    (* DEC-033: the destroy states what it kept, by identifier, so an operator
       never has to infer it from the absence of a snapshot listing. The string
       itself and its tests existed; nothing called it, so the decision was only
       half-implemented -- the setting reached the policy and the report never
       reached the operator. *)
    (match prepared with
     | Aws_prepared snapshot_id ->
       Printf.printf
         "\n%s\n%!"
         (Sol_cli_cloud_lifecycle.retention_report
            ~retention
            ~destroy_snapshot_id:snapshot_id)
     | Gcp_prepared ->
       Printf.printf
         "\n%s\n%!"
         (Sol_cli_cloud_lifecycle.retention_report ~retention ~destroy_snapshot_id:"")
     | Nothing_prepared ->
       Printf.printf
         "\n\
         \  retention: nothing to decide -- this target had no database whose retention \
          a destroy had to settle\n\
          %!");
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
