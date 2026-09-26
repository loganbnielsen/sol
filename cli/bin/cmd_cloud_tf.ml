(* sol cloud plan/apply/destroy — manage cloud infrastructure via Terraform.
   Requires: terraform binary in PATH, cloud credentials in environment. *)

open Cmdliner

(* The destroy execution core (Sol_cli_cloud_destroy) and the result-returning
   helpers below carry failures as values rather than exiting: only the command
   edge turns an outcome into a process exit (REFAC-091). *)
let ( let* ) = Result.bind

(* ── Sol home resolution ─────────────────────────────────────────────────── *)

(* Resolve the Sol monorepo root so we can locate platform/cloud/<provider>/cluster/. *)
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
  let dir = Filename.concat sol_home (Printf.sprintf "platform/cloud/%s/cluster" pname) in
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

let terraform_outcome = Sol_cli_terraform_steps.terraform_outcome
let terraform_stdout = Sol_cli_terraform_steps.terraform_stdout
let apply_asserted = Sol_cli_terraform_steps.apply_asserted

(* The bootstrap-access mechanism's Terraform identity and scope, and the
   reconciliation apply's scope -- the bootstrap mechanism plus the guarded
   resources the inventory represents, never the whole root, so a configured-but-
   unrepresented cluster is not even planned. Per provider, in
   [Sol_cli_provider_capabilities] (REFAC-095). *)
let capabilities = Sol_cli_provider_capabilities.capabilities_of
let bootstrap_matchers provider = (capabilities provider).bootstrap_matchers
let bootstrap_scope provider = (capabilities provider).bootstrap_scope

let reconciliation_scope provider guarded =
  (capabilities provider).reconciliation_scope guarded
;;

(* BUG-057: the flag is relative to the shell, a target's var file to the
   workspace root. *)
let resolve_var_file ~flag ~target =
  let cwd = Sys.getcwd () in
  let workspace_root = Option.value (Sol_cli_workspace.find_root ~dir:cwd) ~default:cwd in
  Sol_cli_terraform_vars.var_file ~cwd ~workspace_root ~flag ~target
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

(* DEC-024: the workspace name comes from the resolved root, so it is the same
   from any descendant directory. *)
let workspace_name = Sol_cli_workspace.current_name

(* The independent postcondition: a fresh read of *this root's* own state. The root
   is [infra_dir], the disposable cloud root -- DEC-043's durable GCP prerequisites
   live in `platform/cloud/gcp/bootstrap`, a different root, so they are not
   residue and are never asserted about here. *)
let post_destroy_state ~infra_dir =
  Sol_cli_destroy_verification.state_evidence
    (match Sol_cli_terraform.show_json ~chdir:infra_dir () with
     | Ok result when result.Sol_cli_process.exit_code = 0 ->
       (match Sol_cli_cloud_destroy.inventory_of_show_json result.stdout with
        | Sol_cli_cloud_destroy.State_empty -> Ok []
        | Sol_cli_cloud_destroy.State_represented _ as state ->
          Ok (Sol_cli_cloud_destroy.addresses state)
        | Sol_cli_cloud_destroy.State_unreadable reason -> Error reason)
     | Ok result -> Error (Printf.sprintf "terraform show exited %d" result.exit_code)
     | Error error ->
       Error ("terraform show could not be run: " ^ Sol_cli_process.error_to_string error))
;;

(* Step 5's one observation, narrowed by DEC-045 / REFAC-094. Terraform's destroy
   plus the empty-state check is the authority for everything Terraform manages,
   so the provider is asked only about what Terraform does not own (residue) and
   what the target promised to keep or not keep (retention). *)
let verification_observation
      ~(destruction : Sol_cli_destruction.t)
      ~infra_dir
      ~cluster
      ~retention
      ~pre_destroy
      ~preparation
  =
  let open Sol_cli_destroy_verification in
  (* The postcondition first, then the derived legs -- stated, not left to the
     unspecified evaluation order of record fields. *)
  let state = post_destroy_state ~infra_dir in
  let sweep = destruction.residue ~pre_destroy ~cluster in
  { state; sweep; retention = destruction.retention ~retention ~pre_destroy ~preparation }
;;

let report_verification observation =
  Printf.printf "%s%!" (Sol_cli_destroy_verification.report observation)
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

(* INFRA-076: before touching a Terraform state, look at the last operation
   against it. Running: never race it and never unlock it -- say so and stop.
   Unresolved (Terraform did not finish its own protocol, or left
   errored.tfstate): a constructive command must not proceed as though nothing
   happened, unless the operator reconciled it and says so; a plan or a destroy
   proceeds with the warning, because neither can construct from the gap. A
   graceful Ctrl-C is Resolved, not suspicious. *)
let guard_previous_operation ~constructive ~accept_unresolved ~chdir ~backend_config =
  match Sol_cli_terraform.previous_operation ~chdir ~backend_config with
  | Sol_cli_supervised.No_previous | Sol_cli_supervised.Resolved _ -> ()
  | Sol_cli_supervised.Running _ as status ->
    lifecycle_error
      (Printf.sprintf
         "a previous Terraform operation against this state is still running and holds \
          its lock. Wait for it to finish; do not unlock it.\n\
         \  %s"
         (Sol_cli_supervised.status_to_string status))
  | Sol_cli_supervised.Unresolved _ as status when not constructive ->
    Printf.eprintf
      "warning: the previous Terraform operation against this state is %s\n%!"
      (Sol_cli_supervised.status_to_string status)
  | Sol_cli_supervised.Unresolved _ as status when accept_unresolved ->
    Sol_cli_terraform.acknowledge_previous_operation ~chdir ~backend_config;
    Printf.eprintf
      "warning: proceeding past an unresolved previous operation, as --accept-unresolved \
       asks: %s\n\
       %!"
      (Sol_cli_supervised.status_to_string status)
  | Sol_cli_supervised.Unresolved _ as status ->
    lifecycle_error
      (Printf.sprintf
         "refusing to apply: the previous Terraform operation against this state is %s\n\
         \  Terraform may have changed the provider without recording it. Reconcile \
          first (inspect the provider and the state; import or remove what diverged, \
          push any errored.tfstate), then re-run with --accept-unresolved. Nothing was \
          changed."
         (Sol_cli_supervised.status_to_string status))
;;

let established_target = function
  | Some target -> target
  | None -> lifecycle_error "cloud lifecycle requires a resolved target"
;;

(* The cluster the cloud root produced, built by its provider's module
   (REFAC-096); [None] when the root has no outputs yet. *)
let cluster_of ~(target_cfg : Sol_cli_config.target) provider infra_dir =
  Sol_cli_provider_registry.of_root provider ~target:target_cfg ~chdir:infra_dir
;;

let process_ok = Sol_cli_cluster.process_ok
let process_output = Sol_cli_cluster.process_output

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
      ~cluster
      ()
  =
  match Sol_cli_cloud_lifecycle.platform_inputs cloud_target cluster with
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
      ~cluster
      ()
  : (string list, string) result
  =
  let* inputs = Sol_cli_cloud_lifecycle.platform_inputs cloud_target cluster in
  Sol_cli_cloud_lifecycle.platform_terraform_vars ~context inputs
;;

let with_cluster_access (cluster : Sol_cli_cluster.t) f =
  match cluster.with_access (fun ~env -> Ok (f env)) with
  | Ok () -> ()
  | Error message -> lifecycle_error message
;;

(* The result-returning cluster access: no [on_error] threading, because the
   elevated-access removal is bracketed structurally around the operation rather
   than handed to each failure branch (FND-0047 / REFAC-091). *)
let with_cluster_access_result
      (cluster : Sol_cli_cluster.t)
      (f : env:(string * string) list -> (unit, string) result)
  : (unit, string) result
  =
  cluster.with_access f
;;

(* INFRA-039: resolve provider credentials for this operation, report the principal
   they belong to, and fail closed if they cannot be resolved. Sol used to inherit
   the ambient environment and assume it still worked: on HARDEN-002 Run 5 Attempt 5
   the SSO session expired mid-run, the CLI still answered for the profile while
   terraform could not refresh, and `sol cloud destroy` could not authenticate
   against a billable target. [leaves_target_standing] says the part that matters —
   a destroy that cannot authenticate leaves infrastructure running and disables the
   only supported path to remove it. *)
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
  Sol_cli_provider_registry.credentials provider ~operation ~leaves_target_standing
;;

let require_credentials ~provider ~operation ~leaves_target_standing =
  match credentials_result ~provider ~operation ~leaves_target_standing with
  | Ok () -> ()
  | Error message -> lifecycle_error message
;;

(* What that check means, in the words its failure is reported with. *)
let cloud_ready_expectation provider = (capabilities provider).cloud_ready_expectation

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

(* Staged through the shared platform definition, which every provider's root
   calls as `module.platform`, so every address goes through that prefix rather
   than being written bare. *)
let platform_prerequisite_targets =
  let address = Sol_cli_cloud_lifecycle.platform_address in
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
(* The guarded resources the Step-2 inventory actually represents, by declared
   address. This is the state side of the scope decision: a configured-but-
   unrepresented resource is not targeted (FND-0030), and the plan assertion
   catches anything a `-target` pulls in anyway. *)
let guarded_addresses_of provider state =
  Sol_cli_cloud_lifecycle.preparations_eligible
    ~state:(Sol_cli_cloud_destroy.addresses state)
    ~desired:(capabilities provider).guarded_addresses
;;

(* What destruction preparation did. The providers differ in what there is to carry
   forward -- AWS's prepared final-snapshot identity has no GCP counterpart, because
   Cloud SQL destroys its backups with the instance -- so the difference is named in
   the type rather than flattened into an option that would have to mean two
   things. The type lives in [Sol_cli_cloud_destroy], because the execution core
   carries it in its typed outcome. *)

(* The Destroy policy's overrides for this provider, given what preparation found.
   Appended after the caller's own variables so the phase policy wins (ADR 0003 /
   HARDEN-002 finding 15). *)
let destroy_policy_vars ~provider ~phase ~retention ~prepared =
  match prepared with
  | Sol_cli_cloud_destroy.Nothing_prepared -> []
  | Sol_cli_cloud_destroy.Prepared { retained } ->
    Sol_cli_cloud_lifecycle.policy_vars
      ~provider
      ~phase
      ~destroy_snapshot_id:(Option.value retained ~default:"")
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
    let cfg =
      Sol_cli_exit.or_exit_with
        Sol_cli_config.error_to_string
        (Sol_cli_config.load_for_target ~target:target_path)
    in
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
       if strict && not (Sol_cli_config.target_declared resolved_target)
       then (
         Printf.eprintf
           "error: target %S is not declared in %s -- terraform apply/destroy require an \
            explicit target, even an empty one, so a typo'd or unintended target can't \
            silently inherit sol.yml's shared defaults and mutate infrastructure anyway.\n"
           target_path
           (Sol_cli_config.target_source resolved_target);
         exit 1);
       let vars =
         Sol_cli_exit.or_exit
           (Sol_cli_terraform_vars.of_config ~workspace:(workspace_name ()) cfg)
       in
       ( Sol_cli_terraform.kv_args vars
       , resolved_target.Sol_cli_config.terraform_var_file
       , Some resolved_target ))
;;

(* SEC-010: before terraform runs at all, refuse any variable the root declares
   [sensitive] when it would reach the argv -- the run log records the terraform
   command line. Which variables are secrets is read from the root itself, so no
   provider is special-cased; whether a required secret was supplied at all is
   Terraform's to enforce. Checked for destroy as well as apply: a root whose
   secret is a required variable needs it on every command. *)
let refuse_sensitive_vars ~infra_dir ~vars =
  match
    Result.bind (Sol_cli_sensitive_vars.declared ~root:infra_dir) (fun sensitive ->
      Sol_cli_sensitive_vars.refuse_on_command_line ~sensitive ~vars)
  with
  | Ok () -> ()
  | Error msg ->
    Printf.eprintf "\nerror: %s\n%!" msg;
    exit 1
;;

(* Cleanup is independent evidence: a removal failure is reported alongside whatever
   else the run did, never replaced by it and never replacing it (HARDEN-004 step 4,
   preserving steps 2 and 3). *)
let report_cleanup_evidence = function
  | Sol_cli_cloud_destroy.Cleanup_failed message ->
    Printf.eprintf
      "warning: removing the bootstrap access failed (%s); the elevated access may still \
       be applied\n\
       %!"
      message
  | Sol_cli_cloud_destroy.Cleanup_not_needed | Sol_cli_cloud_destroy.Cleanup_succeeded ->
    ()
;;

(* REFAC-091: the concrete dependencies of [Sol_cli_cloud_apply.execute] for one
   target. Provider-specific steps come from the target's cluster (REFAC-096): on
   AWS the whoami gate, window control and de-escalation check are the cluster's
   bootstrap window; GCP's window lives in the platform root, so its cluster has
   none to observe. Nothing here selects a provider for them. *)
let terraform_failure r =
  terraform_outcome r
  |> Result.map_error (fun message -> Sol_cli_cloud_apply.Terraform_failed message)
;;

let with_cluster_access_apply (cluster : Sol_cli_cluster.t) f =
  (* The access itself fails with a string; the callback keeps its own typed
     failure, so a Terraform failure inside is still reported as one. *)
  match cluster.with_access (fun ~env -> Ok (f env)) with
  | Ok result -> result
  | Error message -> Error (Sol_cli_cloud_apply.Refused message)
;;

(* INFRA-034: the install must not be judged on one sample taken the instant the
   apply returns. Helm reporting a release as deployed says the objects were
   created, not that the controllers behind them are serving: on a fresh install
   every native readiness endpoint is still starting, so a single sample reports a
   healthy platform as Unmet. So wait, bounded, and say what is still unmet while
   waiting -- the wait is evidence, and it must not hide a genuine failure. *)
let await_platform_readiness ~provider ~env =
  let sample () =
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
  let deadline_s =
    (* Generous because a fresh install's controllers need minutes. Overridable so
       a harness can bound the wait rather than wait it out. *)
    match Sys.getenv_opt "SOL_PLATFORM_READINESS_TIMEOUT_S" with
    | Some raw ->
      (match float_of_string_opt raw with
       | Some seconds when seconds >= 0. -> seconds
       | _ -> 900.)
    | None -> 900.
  in
  let poll_s = 15. in
  let deadline = Unix.gettimeofday () +. deadline_s in
  let waiting_since = Unix.gettimeofday () in
  let rec await () =
    let checks = sample () in
    let unmet = unmet_count checks in
    if unmet = 0 || Unix.gettimeofday () >= deadline
    then checks
    else (
      Printf.printf
        "  awaiting platform readiness: %d check(s) unmet, %.0fs elapsed\n%!"
        unmet
        (Unix.gettimeofday () -. waiting_since);
      Unix.sleepf poll_s;
      await ())
  in
  await ()
;;

(* The flag that confirms a guarded removal (INFRA-074), named once: the refusal is
   built in the generic apply sequence, which must not carry a provider's product name
   (AUDIT-POST-002). *)
let confirm_guarded_removal_flag = "confirm-ecr-removal"

let apply_deps
      ~confirm_ecr_removal
      ~provider
      ~pname
      ~run_log
      ~infra_dir
      ~platform_dir
      ~platform_backend
      ~var_files
      ~vars
      ~cloud_target
      ~(target_cfg : Sol_cli_config.target)
  =
  (* INFRA-074 / FND-0043: the cloud apply runs from a saved plan that is read
     first, and what is applied is the plan that was read. *)
  let plan_file = Filename.temp_file "sol-cloud-apply-" ".tfplan" in
  let discard_plan () =
    List.iter
      (fun f ->
         try Sys.remove f with
         | Sys_error _ -> ())
      [ plan_file; plan_file ^ ".args" ]
  in
  (* An interrupt still ends the process through [exit]; the sequence's own
     bracket covers every other path. *)
  at_exit discard_plan;
  let platform_apply ~name ~scope env platform_vars =
    terraform_failure
      (Sol_cli_run_log.run_phase run_log ~name (fun () ->
         Sol_cli_terraform.apply
           ~env
           ~scope
           ~chdir:platform_dir
           ~var_files:[]
           ~vars:platform_vars
           ()))
  in
  { Sol_cli_cloud_apply.substrate_exists =
      (fun () -> cluster_of ~target_cfg provider infra_dir |> Result.map Option.is_some)
  ; plan =
      (fun () ->
        let* () =
          terraform_failure
            (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan" (fun () ->
               Sol_cli_terraform.plan_saved
                 ~scope:Sol_cli_terraform.whole_root
                 ~chdir:infra_dir
                 ~var_files
                 ~vars:
                   (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:true) @ vars)
                 ~out:plan_file
                 ()))
        in
        (* The plan JSON carries sensitive values in plain text (e.g. db_password),
           so it never passes through [run_phase]; only the classified changes are
           logged (SEC-008). *)
        match
          Sol_cli_terraform.show_saved_plan
            ~run_log
            ~phase:"terraform-plan-show"
            ~chdir:infra_dir
            ~plan_file
            ()
        with
        | Ok (_, changes) -> Ok changes
        | Error message ->
          Error
            (Sol_cli_cloud_apply.Refused ("could not read the cloud plan: " ^ message)))
  ; guarded_removals = (capabilities provider).guarded_removals
  ; confirm_guarded_removal = confirm_ecr_removal
  ; confirmation_flag = "--" ^ confirm_guarded_removal_flag
  ; apply_plan =
      (fun () ->
        terraform_failure
          (Sol_cli_run_log.run_phase run_log ~name:"terraform-apply" (fun () ->
             Sol_cli_terraform.apply_saved ~chdir:infra_dir ~plan_file ())))
  ; discard_plan
  ; outputs = (fun () -> cluster_of ~target_cfg provider infra_dir)
  ; (* DEC-040. The gate first: it fires at the moment a fresh endpoint is least
       likely to answer, so it must not be preceded by anything else that needs a
       working cluster. Then the control, which must observe a bootstrap-only
       capability *permitted*, because a later denial is not a transition unless
       the capability was shown to work first. *)
    open_window =
      (fun (cluster : Sol_cli_cluster.t) ->
        match cluster.bootstrap_window with
        | Verified window ->
          let* () = window.gate () in
          Result.map Option.some (window.observe ())
        | No_role_declared | Closed_by_platform_root -> Ok None)
  ; platform_vars = (fun cluster -> platform_vars_of_result ~cloud_target ~cluster ())
  ; cloud_ready =
      (fun (cluster : Sol_cli_cluster.t) ->
        if cluster.ready ()
        then Ok ()
        else
          Error
            (Printf.sprintf
               "%s cloud substrate is not Ready: %s"
               pname
               (cloud_ready_expectation provider)))
  ; with_cluster_access = with_cluster_access_apply
  ; platform_init =
      (fun () -> terraform_failure (terraform_init run_log platform_dir platform_backend))
  ; platform_installed = (fun env -> crds_established env)
  ; apply_prerequisites =
      platform_apply
        ~name:"platform-prerequisites-apply"
        ~scope:platform_prerequisite_targets
  ; await_crds =
      (fun env ->
        process_ok
          ~env
          [ "kubectl"
          ; "wait"
          ; "--for=condition=Established"
          ; "crd/certificates.cert-manager.io"
          ; "crd/clusterissuers.cert-manager.io"
          ; "--timeout=180s"
          ])
  ; apply_platform =
      platform_apply ~name:"platform-apply" ~scope:Sol_cli_terraform.whole_root
  ; await_readiness = (fun env -> await_platform_readiness ~provider ~env)
  ; remove_bootstrap_access =
      (fun () ->
        terraform_failure
          (Sol_cli_run_log.run_phase
             run_log
             ~name:"provisioner-bootstrap-access-remove"
             (fun () ->
                Sol_cli_terraform.apply
                  ~scope:Sol_cli_terraform.whole_root
                  ~chdir:infra_dir
                  ~var_files
                  ~vars:
                    (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:false)
                     @ vars)
                  ())))
  ; (* DEC-040 applies to the AWS bootstrap access, which Sol revokes itself. GCP's
       window lives in the platform root and is closed by applying that root, so
       there is no Sol-side revocation to verify. *)
    verify_deescalation =
      (fun (cluster : Sol_cli_cluster.t) _control ->
        match cluster.bootstrap_window with
        | Verified window ->
          (match window.deescalated () with
           | Ok () ->
             Printf.printf "  de-escalation verified as %s\n%!" window.principal;
             Ok ()
           | Error verdict -> Error ("de-escalation could not be established: " ^ verdict))
        | No_role_declared ->
          (* A target that declares no provisioner role had nothing elevated. Said out
             loud rather than skipped: a silently skipped verification is the
             false-pass shape DEC-040 exists to remove. *)
          Printf.printf
            "  no provisioner role declared: no bootstrap elevation to verify\n%!";
          Ok ()
        | Closed_by_platform_root -> Ok ())
  ; provisioner_effective = provisioner_rbac_established
  ; report = (fun line -> Printf.printf "%s\n%!" line)
  }
;;

let cloud_init
      ?(confirm_ecr_removal = false)
      ?(accept_unresolved = false)
      ~target
      ~var_file
      ~vars
      ~action
      ()
  =
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
  let var_file = resolve_var_file ~flag:var_file ~target:config_var_file in
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
  let var_files = Option.to_list var_file in
  refuse_sensitive_vars ~infra_dir ~vars;
  Printf.printf "\nInitializing cloud infrastructure (%s)...\n%!" pname;
  (* INFRA-039: credentials are resolved again here, per mutating stage,
       rather than assumed from process start -- a platform stage runs many
       minutes after the cloud stage. *)
  (match action with
   | Plan -> ()
   | _ ->
     require_credentials ~provider ~operation:"applying" ~leaves_target_standing:false);
  guard_previous_operation
    ~constructive:(action = Apply)
    ~accept_unresolved
    ~chdir:infra_dir
    ~backend_config:cloud_backend;
  if action = Apply
  then
    guard_previous_operation
      ~constructive:true
      ~accept_unresolved
      ~chdir:platform_dir
      ~backend_config:platform_backend;
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
    (match cluster_of ~target_cfg provider infra_dir with
     | Ok None ->
       report_phase
         "Platform prerequisites"
         (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist");
       report_phase
         "Platform substrate"
         (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist")
     | Error message -> lifecycle_error message
     | Ok (Some cluster) ->
       let platform_vars = platform_vars_of ~cloud_target ~cluster () in
       (* An unavailable cluster credential is not a deferred phase: it is an
          unavailable lifecycle prerequisite, so plan exits non-zero. Deferral is
          reserved for phases whose concrete prerequisite is simply not
          established yet and whose establishment would itself be a mutation. *)
       with_cluster_access cluster (fun env ->
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
    let outcome =
      Sol_cli_cloud_apply.execute
        ~deps:
          (apply_deps
             ~confirm_ecr_removal
             ~provider
             ~pname
             ~run_log
             ~infra_dir
             ~platform_dir
             ~platform_backend
             ~var_files
             ~vars
             ~cloud_target
             ~target_cfg)
    in
    (* One place maps the typed outcome to a process exit (REFAC-091): 0 once the
       target is Ready, 1 for any failure -- after the bootstrap-window cleanup, if
       the run needed one, has been reported alongside it. *)
    (match outcome with
     | Sol_cli_cloud_apply.Applied ->
       Printf.printf "\nProvisioned endpoints:\n%!";
       print_outputs infra_dir;
       Printf.printf "\nDone.\n%!"
     | Sol_cli_cloud_apply.Apply_failed { failure; cleanup } ->
       report_cleanup_evidence cleanup;
       (match failure with
        | Sol_cli_cloud_apply.Terraform_failed message ->
          Printf.eprintf "\n%s\n%!" message
        | Sol_cli_cloud_apply.Refused message -> Printf.eprintf "error: %s\n%!" message);
       exit 1)
;;

(* A preparation that failed but permitted destruction does not change the exit
   code, so it is said out loud rather than left to be inferred. *)
let report_degradations = function
  | [] -> ()
  | degradations ->
    List.iter
      (fun message ->
         Printf.eprintf
           "warning: a preparation degraded and destruction continued -- %s\n%!"
           message)
      degradations;
    Printf.eprintf
      "warning: destruction reached absence with %d degraded preparation(s)\n%!"
      (List.length degradations)
;;

let cloud_destroy ~target ~var_file ~vars ~action () =
  check_terraform ();
  let provider = provider_of_target_path target in
  let pname, infra_dir = infra_dir provider in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-destroy" () in
  let config_vars, config_var_file, target_cfg =
    config_vars ~strict:(action = Apply) (Some target)
  in
  let var_file = resolve_var_file ~flag:var_file ~target:config_var_file in
  let vars = config_vars @ vars in
  refuse_sensitive_vars ~infra_dir ~vars;
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
  guard_previous_operation
    ~constructive:false
    ~accept_unresolved:false
    ~chdir:infra_dir
    ~backend_config:cloud_backend;
  (* AUDIT-POST-004: the platform root is a second Terraform state, and destroy works
     in it (init, the destroy preview, the platform teardown). Apply guards both roots
     (above, in [cloud_init]); destroy guarded only the cloud root, so a platform
     operation still running produced Terraform's backend-lock error instead of Sol's
     own report. Same non-constructive policy as the cloud root: [Running] refuses,
     [Unresolved] is reported and destruction proceeds, because nothing here constructs
     from the gap. *)
  guard_previous_operation
    ~constructive:false
    ~accept_unresolved:false
    ~chdir:(platform_dir provider)
    ~backend_config:(Sol_cli_cloud_lifecycle.platform_backend cloud_target);
  let var_files = Option.to_list var_file in
  (* REFAC-097: the provider's retention and residue steps for this destroy. *)
  let destruction =
    Sol_cli_provider_registry.destruction
      provider
      { Sol_cli_destruction.run_log
      ; infra_dir
      ; var_files
      ; vars
      ; target = target_cfg
      ; resolved_var = (fun key -> resolved_var key ~var_files ~vars ~default:None)
      }
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
        match cluster_of ~target_cfg provider infra_dir with
        | Ok (Some cluster) ->
          let platform_dir = platform_dir provider in
          let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
          let* platform_vars =
            platform_vars_of_result
              ~context:Sol_cli_cloud_lifecycle.Destruction
              ~cloud_target
              ~cluster
              ()
          in
          with_cluster_access_result cluster (fun ~env ->
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
    let cluster_ref = ref None in
    let observed_window = ref None in
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
      match !cluster_ref with
      | Some (cluster : Sol_cli_cluster.t) -> cluster.name
      | None ->
        (match resolved_var "cluster_name" ~var_files ~vars ~default:None with
         | Some name -> name
         | None -> workspace_name ())
    in
    (* The platform teardown, result-returning. The elevated bootstrap access is
       opened by the bracket ([reconcile_and_enable]) and removed by its cleanup,
       so this never threads an [on_error]: a failure returns, and the removal
       happens structurally (FND-0047). *)
    let destroy_platform_result ~cluster () : (unit, string) result =
      let platform_dir = platform_dir provider in
      let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
      let* platform_vars =
        platform_vars_of_result
          ~context:Sol_cli_cloud_lifecycle.Destruction
          ~cloud_target
          ~cluster
          ()
      in
      with_cluster_access_result cluster (fun ~env ->
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
            match cluster_of ~target_cfg provider infra_dir with
            | Ok (Some cluster) ->
              cluster_ref := Some cluster;
              Sol_cli_cloud_destroy.Outputs_available
            | Ok None ->
              Sol_cli_cloud_destroy.Outputs_unavailable "no install outputs are published"
            | Error reason -> Sol_cli_cloud_destroy.Outputs_unavailable reason)
      ; prepare =
          (fun ~state ->
            (* The edge answers with the typed preparation; the core decides the
               consequence. Only a successful preparation updates [prepared_ref],
               which is what the Destroy policy's variables are computed from --
               a failed preparation must never look like a finished one. *)
            let outcome =
              destruction.prepare
                ~retention
                ~cluster_name:(prepare_cluster_name ())
                ~state
            in
            (match outcome with
             | Sol_cli_cloud_lifecycle.Prepared preparation -> prepared_ref := preparation
             | Sol_cli_cloud_lifecycle.Nothing_to_prepare
             | Sol_cli_cloud_lifecycle.Preparation_failed _ -> ());
            outcome)
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
            match !cluster_ref with
            | Some cluster -> destroy_platform_result ~cluster ()
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
            match !cluster_ref with
            | Some { Sol_cli_cluster.bootstrap_window = Verified window; _ } ->
              let* () = window.observe () in
              observed_window := Some window;
              Ok ()
            | Some { bootstrap_window = No_role_declared; _ } ->
              (* A target that declares no provisioner role elevated nothing; said out
                 loud rather than skipped, the same as on the install path. *)
              Printf.printf
                "  no provisioner role declared: no bootstrap elevation to verify\n%!";
              Ok ()
            | Some { bootstrap_window = Closed_by_platform_root; _ } -> Ok ()
            | None ->
              Printf.printf
                "  bootstrap window: not observed (no install outputs to reach the \
                 cluster with)\n\
                 %!";
              Ok ())
      ; verify_window_after =
          (fun () ->
            match !observed_window with
            | None -> Ok ()
            | Some window ->
              (match window.deescalated () with
               | Ok () -> Ok ()
               | Error verdict ->
                 Error
                   (Printf.sprintf
                      "the bootstrap access was removed but its effective removal could \
                       not be verified (%s). Proceeding: destroying the substrate \
                       removes the access with it, and teardown is not blocked by a \
                       probe that can fail (ADR 0003 invariant 6)."
                      verdict)))
      ; destroy_substrate =
          (fun () ->
            (* Provider glue that must run before the substrate destroy that needs
               it: on AWS, waiting for the ingress load balancer to drain. *)
            destruction.before_substrate_destroy ();
            terraform_outcome
              (Sol_cli_run_log.run_phase run_log ~name:"terraform-destroy" (fun () ->
                 Sol_cli_terraform.destroy
                   ~chdir:infra_dir
                   ~var_files
                   ~vars:(destroy_apply_vars ())
                   ())))
      ; verify_destruction =
          (fun ~pre_destroy ~preparation ->
            verification_observation
              ~destruction
              ~infra_dir
              ~cluster:!cluster_ref
              ~retention
              ~pre_destroy
              ~preparation)
      ; report = (fun message -> Printf.printf "%s\n%!" message)
      ; warn = (fun message -> Printf.eprintf "%s\n%!" message)
      }
    in
    (* One place maps the typed outcome to a process exit: 0 when absence was
       reached and verified (a degraded preparation is the warning above, not a
       different code); 1 for a blocked or failed destroy. 2 stays reserved for this
       CLI's refusal / cannot-proceed-as-requested semantics. Success *means* every
       required postcondition was positively established; an UNKNOWN observation is
       a failure. *)
    let outcome = Sol_cli_cloud_destroy.execute ~deps in
    (match outcome with
     | Sol_cli_cloud_destroy.Destroy_succeeded { degradations; cleanup; verification; _ }
       ->
       report_cleanup_evidence cleanup;
       report_degradations degradations;
       (* The evidence report carries the retention statement, because retention is
          now observed rather than rendered from the policy (DEC-033 / FND-0046). *)
       report_verification verification;
       Printf.printf
         (if degradations = []
          then "\nDone.\n%!"
          else "\nDone, with a degraded preparation.\n%!")
     | Sol_cli_cloud_destroy.Destroy_blocked { guarantee } ->
       (* Destruction did not happen, so there is no postcondition to verify and the
          step-5 observation deliberately never ran. *)
       Printf.eprintf
         "error: destruction is blocked -- proceeding would violate a destruction-time \
          guarantee this target declared: %s\n\
          %!"
         guarantee
     | Sol_cli_cloud_destroy.Destroy_failed
         { failure; degradations; cleanup; verification } ->
       (* A cleanup failure is evidence, not silence: it is reported alongside the
          failure that stopped the run, never replaced by it. The verification
          evidence is reported too when the run reached it -- what was observed is
          part of why the run failed. *)
       report_cleanup_evidence cleanup;
       report_degradations degradations;
       (match verification with
        | Some verification -> report_verification verification
        | None -> ());
       Printf.eprintf "error: %s\n%!" (Sol_cli_cloud_destroy.failure_message failure));
    exit (Sol_cli_cloud_destroy.exit_code outcome)
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
        [ confirm_guarded_removal_flag ]
        ~doc:
          "Allow an apply whose plan deletes a resource the provider declares guarded \
           (AWS: ECR repositories, and every image in them). Without it such an apply is \
           refused before anything changes.")
;;

(* INFRA-076 *)
let accept_unresolved_flag =
  Arg.(
    value
    & flag
    & info
        [ "accept-unresolved" ]
        ~doc:
          "Proceed although the previous Terraform operation against this state ended \
           unresolved (Terraform was killed before finishing its own shutdown, or left \
           errored.tfstate). Use it only after reconciling: inspecting the provider and \
           the state, and importing, removing or pushing what diverged. Without it such \
           an apply is refused before anything changes.")
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
      const (fun target var_file vars confirm_ecr_removal accept_unresolved ->
        cloud_init
          ~confirm_ecr_removal
          ~accept_unresolved
          ~target
          ~var_file
          ~vars
          ~action:Apply
          ())
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ confirm_ecr_removal_flag
      $ accept_unresolved_flag)
;;

let destroy_cmd =
  let doc =
    "Destroy cloud infrastructure via Terraform. Requires the same target/provider used \
     with apply."
  in
  (* HARDEN-004 step 4's exit-code contract, in the interface an operator or a script
     actually reads. *)
  let man =
    [ `S Manpage.s_description
    ; `P
        "Destruction proceeds even when a best-effort preparation -- lowering a deletion \
         guard -- fails or its plan is refused: the failure is reported, the unsafe \
         apply is never executed, and what Terraform represents is still destroyed. Only \
         a failure that stands for a destruction-time guarantee the target itself \
         declared (such as `destroy_retention: final-snapshot`, which could not be \
         prepared) blocks destruction and leaves the target standing."
    ; `S "EXIT STATUS"
    ; `P
        "0 -- destruction reached absence, and every applicable preparation succeeded or \
         had nothing to do."
    ; `P
        "3 -- destruction reached absence, but one or more best-effort preparations \
         failed or were refused. Each one is reported on stderr."
    ; `P
        "1 -- destruction did not reach its postcondition: it failed, it was blocked by \
         a declared guarantee, absence could not be verified, or the elevated bootstrap \
         access could not be removed. The reason is named on stderr."
    ; `P "2 is not used by this command."
    ]
  in
  Cmd.v
    (Cmd.info "destroy" ~doc ~man)
    Term.(
      const (fun target var_file vars action ->
        cloud_destroy ~target ~var_file ~vars ~action ())
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ action_term)
;;
