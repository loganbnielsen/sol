(* REFAC-139, part D: the concrete wiring of `sol cloud plan|apply|destroy` --
   the dependencies [Sol_cli_cloud_apply.execute] and [Sol_cli_cloud_destroy.execute]
   run on for one target, and the plan and destroy-preview sequences. It lived in
   `cmd_cloud_tf.ml`; the command now resolves the request, calls these, and
   renders the typed outcome. Nothing here exits the process, and nothing prints:
   progress goes through [Sol_cli_report]. *)

open Result.Syntax

let terraform_outcome = Sol_cli_terraform_steps.terraform_outcome
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
     | Ok result ->
       (match Sol_cli_cloud_destroy.inventory_of_show_json result.stdout with
        | Sol_cli_cloud_destroy.State_empty -> Ok []
        | Sol_cli_cloud_destroy.State_represented _ as state ->
          Ok (Sol_cli_cloud_destroy.addresses state)
        | Sol_cli_cloud_destroy.State_unreadable reason -> Error reason)
     | Error (Sol_cli_process.Non_zero result) ->
       Error (Printf.sprintf "terraform show exited %d" result.exit_code)
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

(* DEC-050: the Terraform roots in Sol's assets are immutable and only read by
   the command, for the variables a root declares. Terraform itself runs in a
   per-state working directory (Sol_cli_terraform_workdir) keyed by the backend it
   works on, which every init first materializes from those assets. *)
let workdir provider role ~backend_config =
  Sol_cli_terraform_workdir.chdir ~provider ~role ~backend_config
;;

let materialize_workdir ~assets provider role ~backend_config =
  Sol_cli_terraform_workdir.materialize ~assets ~provider ~role ~backend_config
  |> Result.map ignore
;;

let terraform_init run_log infra_dir backend_config =
  Sol_cli_run_log.run_phase run_log ~name:"terraform-init" (fun () ->
    Sol_cli_terraform.init ~chdir:infra_dir ~backend_config ())
;;

(* DEC-050: every Terraform use of a state begins with init, so init is where its
   working directory is materialized from the authoritative assets. A
   materialization failure is Sol's refusal; an init failure is Terraform's. *)
let init ~assets run_log ~provider ~role backend_config =
  match materialize_workdir ~assets provider role ~backend_config with
  | Error message -> Error (Sol_cli_cloud_apply.Refused message)
  | Ok () ->
    terraform_init run_log (workdir provider role ~backend_config) backend_config
    |> terraform_outcome
    |> Result.map_error (fun message -> Sol_cli_cloud_apply.Terraform_failed message)
;;

let failure_message = function
  | Sol_cli_cloud_apply.Terraform_failed message | Sol_cli_cloud_apply.Refused message ->
    message
;;

(* REFAC-091: the form for the destroy sequence, which carries an init failure in
   its typed outcome as a message. *)
let init_result ~assets run_log ~provider ~role backend_config =
  init ~assets run_log ~provider ~role backend_config |> Result.map_error failure_message
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
   widen rather than four. *)
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

(* The access itself fails with a string, mapped by [refused]; the callback keeps
   its own typed failure, so a Terraform failure inside is still reported as one. *)
let with_cluster_access (cluster : Sol_cli_cluster.t) ~refused f =
  match cluster.with_access (fun ~env -> Ok (f env)) with
  | Ok result -> result
  | Error message -> Error (refused message)
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
let credentials_result ~provider ~operation ~leaves_target_standing
  : (unit, string) result
  =
  Sol_cli_provider_registry.credentials provider ~operation ~leaves_target_standing
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

(* REFAC-091: the concrete dependencies of [Sol_cli_cloud_apply.execute] for one
   target. Provider-specific steps come from the target's cluster (REFAC-096): on
   AWS the whoami gate, window control and de-escalation check are the cluster's
   bootstrap window; GCP's window lives in the platform root, so its cluster has
   none to observe. Nothing here selects a provider for them. *)
let terraform_failure r =
  terraform_outcome r
  |> Result.map_error (fun message -> Sol_cli_cloud_apply.Terraform_failed message)
;;

let with_cluster_access_apply cluster f =
  with_cluster_access cluster ~refused:(fun m -> Sol_cli_cloud_apply.Refused m) f
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
      (checks
       |> List.filter (fun (_, state) ->
         match state with
         | Sol_cli_cloud_lifecycle.Established -> false
         | Sol_cli_cloud_lifecycle.Unmet _ -> true))
  in
  let deadline_s =
    (* Generous because a fresh install's controllers need minutes. Overridable so
       a harness can bound the wait rather than wait it out. *)
    match Sol_cli_string.env "SOL_PLATFORM_READINESS_TIMEOUT_S" with
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
      Sol_cli_report.app
        "  awaiting platform readiness: %d check(s) unmet, %.0fs elapsed"
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
      ~assets
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
    List.iter Sol_cli_fs.remove_reporting [ plan_file; plan_file ^ ".args" ]
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
      (fun cluster ->
        match cluster.bootstrap_window with
        | Verified window ->
          let* () = window.gate () in
          Result.map Option.some (window.observe ())
        | No_role_declared | Closed_by_platform_root -> Ok None)
  ; platform_vars = (fun cluster -> platform_vars_of_result ~cloud_target ~cluster ())
  ; substrate_supported =
      (fun () ->
        match
          (Sol_cli_provider_capabilities.capabilities_of provider).cluster_substrate
        with
        | None -> Ok ()
        | Some observe ->
          (match cluster_of ~target_cfg provider infra_dir with
           | Ok None ->
             (* No cluster yet: a fresh target, which is exactly what Sol is about to provision
                Standard into. *)
             Ok ()
           | Ok (Some cluster) ->
             (* The project is named from the root's own outputs, as the quota read does. *)
             let outputs_json =
               match Sol_cli_terraform.output_json ~chdir:infra_dir () with
               | Ok result -> result.Sol_cli_process.stdout
               | Error _ -> ""
             in
             (match
                Result.bind
                  (observe
                     ~outputs_json
                     ~region:target_cfg.region
                     ~cluster_name:cluster.Sol_cli_cluster.name)
                  Sol_cli_cluster_substrate.acceptable
              with
              | Ok () -> Ok ()
              | Error message -> Error (Sol_cli_cloud_apply.Refused message))
           | Error _ ->
             (* An unreadable cloud root is `substrate_exists`'s refusal to make, and that runs
                first, so there is no cluster here for this check to reconcile with. *)
             Ok ()))
  ; observe_disk_quota =
      (fun _ ->
        match (Sol_cli_provider_capabilities.capabilities_of provider).disk_quota with
        | None -> Ok None
        | Some observe ->
          (match Sol_cli_terraform.output_json ~chdir:infra_dir () with
           | Error _ ->
             Error
               "could not read the cloud root's outputs to scope the disk-quota \
                observation"
           | Ok outputs ->
             Result.map
               Option.some
               (observe ~outputs_json:outputs.stdout ~region:target_cfg.region)))
  ; cloud_ready =
      (fun cluster ->
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
      (fun () ->
        match
          materialize_workdir
            ~assets
            provider
            Sol_cli_platform_assets.Platform
            ~backend_config:platform_backend
        with
        | Error message -> Error (Sol_cli_cloud_apply.Refused message)
        | Ok () ->
          terraform_failure (terraform_init run_log platform_dir platform_backend))
  ; platform_installed = crds_established
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
      (fun cluster _control ->
        match cluster.bootstrap_window with
        | Verified window ->
          (match window.deescalated () with
           | Ok () ->
             Sol_cli_report.app "  de-escalation verified as %s" window.principal;
             Ok ()
           | Error verdict -> Error ("de-escalation could not be established: " ^ verdict))
        | No_role_declared ->
          (* A target that declares no provisioner role had nothing elevated. Said out
             loud rather than skipped: a silently skipped verification is the
             false-pass shape DEC-040 exists to remove. *)
          Sol_cli_report.app
            "  no provisioner role declared: no bootstrap elevation to verify";
          Ok ()
        | Closed_by_platform_root -> Ok ())
  ; provisioner_effective = provisioner_rbac_established
  ; report = (fun line -> Sol_cli_report.app "%s" line)
  }
;;

(* `sol cloud plan`'s phases after the cloud root is initialized: the cloud root's
   plan, then the platform's two phases, each planned or reported as deferred. *)
let plan
      ~assets
      ~run_log
      ~provider
      ~cloud_target
      ~(target_cfg : Sol_cli_config.target)
      ~infra_dir
      ~platform_dir
      ~platform_backend
      ~var_files
      ~vars
  =
  let refused r = Result.map_error (fun m -> Sol_cli_cloud_apply.Refused m) r in
  let* () =
    terraform_failure
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan" (fun () ->
         Sol_cli_terraform.plan
           ~scope:Sol_cli_terraform.whole_root
           ~chdir:infra_dir
           ~var_files
           ~vars
           ()))
  in
  let report_phase name = function
    | Sol_cli_cloud_lifecycle.Plannable -> Sol_cli_report.app "\n%s\n  PLANNED" name
    | Sol_cli_cloud_lifecycle.Deferred reason ->
      Sol_cli_report.app "\n%s\n  DEFERRED — %s" name reason
  in
  match cluster_of ~target_cfg provider infra_dir with
  | Ok None ->
    report_phase
      "Platform prerequisites"
      (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist");
    report_phase
      "Platform substrate"
      (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist");
    Ok ()
  | Error message -> Error (Sol_cli_cloud_apply.Refused message)
  | Ok (Some cluster) ->
    let* platform_vars = platform_vars_of_result ~cloud_target ~cluster () |> refused in
    (* An unavailable cluster credential is not a deferred phase: it is an
      unavailable lifecycle prerequisite, so plan exits non-zero. Deferral is
      reserved for phases whose concrete prerequisite is simply not
      established yet and whose establishment would itself be a mutation. *)
    with_cluster_access
      cluster
      ~refused:(fun m -> Sol_cli_cloud_apply.Refused m)
      (fun env ->
         (* [can-i --list] needs authentication only, so it succeeds with an empty
        rule set when the provisioner's RBAC is simply not established yet, and
        fails when the cluster credential is unavailable. Deferral is honest
        only in the former case: the plan exit-status contract makes an
        unavailable credential a non-zero result, not a deferred phase. The
        default [can-i] checks cannot tell the two apart -- both return 1. *)
         let* () =
           if process_ok ~env [ "kubectl"; "auth"; "can-i"; "--list" ]
           then Ok ()
           else
             Error
               (Sol_cli_cloud_apply.Refused
                  "could not authenticate to the cluster as the platform provisioner; \
                   refusing to report an unavailable cluster credential as a deferred \
                   phase")
         in
         let rbac_established = provisioner_rbac_established env in
         let crds_established = rbac_established && crds_established env in
         let prerequisites, substrate =
           Sol_cli_cloud_lifecycle.platform_plan_phases
             ~cluster_exists:true
             ~rbac_established
             ~crds_established
         in
         let* () =
           match prerequisites with
           | Sol_cli_cloud_lifecycle.Plannable ->
             let* () =
               init
                 ~assets
                 run_log
                 ~provider
                 ~role:Sol_cli_platform_assets.Platform
                 platform_backend
             in
             terraform_failure
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
           | Sol_cli_cloud_lifecycle.Deferred _ -> Ok ()
         in
         let* () =
           match substrate with
           | Sol_cli_cloud_lifecycle.Plannable ->
             terraform_failure
               (Sol_cli_run_log.run_phase run_log ~name:"platform-plan" (fun () ->
                  Sol_cli_terraform.plan
                    ~env
                    ~scope:Sol_cli_terraform.whole_root
                    ~chdir:platform_dir
                    ~var_files:[]
                    ~vars:platform_vars
                    ()))
           | Sol_cli_cloud_lifecycle.Deferred _ -> Ok ()
         in
         report_phase "Platform prerequisites" prerequisites;
         report_phase "Platform substrate" substrate;
         Ok ())
;;

(* `sol cloud destroy`'s read-only preview. B / FND-0044 point 2 applies here
   too: unusable install outputs defer the *wiring*, they do not decide that the
   substrate is absent. *)
let destroy_preview
      ~assets
      ~run_log
      ~provider
      ~cloud_target
      ~(target_cfg : Sol_cli_config.target)
      ~infra_dir
      ~var_files
      ~vars
  : (unit, string) result
  =
  let* () =
    match cluster_of ~target_cfg provider infra_dir with
    | Ok (Some cluster) ->
      let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
      let platform_dir =
        workdir provider Sol_cli_platform_assets.Platform ~backend_config:platform_backend
      in
      let* platform_vars =
        platform_vars_of_result
          ~context:Sol_cli_cloud_lifecycle.Destruction
          ~cloud_target
          ~cluster
          ()
      in
      with_cluster_access_result cluster (fun ~env ->
        let* () =
          init_result
            ~assets
            run_log
            ~provider
            ~role:Sol_cli_platform_assets.Platform
            platform_backend
        in
        terraform_outcome
          (Sol_cli_run_log.run_phase run_log ~name:"platform-plan-destroy" (fun () ->
             Sol_cli_terraform.plan_destroy
               ~env
               ~chdir:platform_dir
               ~var_files:[]
               ~vars:platform_vars
               ())))
    | Ok None ->
      Sol_cli_report.app
        "  Platform destroy DEFERRED — no install outputs are published, so the platform \
         teardown cannot be wired.";
      Ok ()
    | Error reason ->
      Sol_cli_report.app
        "  Platform destroy DEFERRED — install outputs are unavailable (%s), so the \
         platform teardown cannot be wired."
        reason;
      Ok ()
  in
  terraform_outcome
    (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan-destroy" (fun () ->
       Sol_cli_terraform.plan_destroy ~chdir:infra_dir ~var_files ~vars ()))
;;

(* REFAC-097: the provider's retention and residue steps for one destroy. *)
let destruction
      ~run_log
      ~provider
      ~(target_cfg : Sol_cli_config.target)
      ~infra_dir
      ~var_files
      ~vars
  =
  Sol_cli_provider_registry.destruction
    provider
    { Sol_cli_destruction.run_log
    ; infra_dir
    ; var_files
    ; vars
    ; target = target_cfg
    ; resolved_var = (fun key -> Sol_cli_terraform_vars.resolved key ~var_files ~vars)
    }
;;

(* The concrete dependencies of [Sol_cli_cloud_destroy.execute]. The one state
   observation is captured here so the policy vars can use it; the library
   classifies it and owns the decisions. Substrate existence comes from this
   inventory, never from the install-time outputs contract (B / FND-0044 point
   2). *)
let destroy_deps
      ~assets
      ~run_log
      ~provider
      ~cloud_target
      ~(target_cfg : Sol_cli_config.target)
      ~infra_dir
      ~cloud_backend
      ~var_files
      ~vars
      ~retention
      ~(destruction : Sol_cli_destruction.t)
  : Sol_cli_cloud_destroy.deps
  =
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
      (match Sol_cli_terraform_vars.resolved "cluster_name" ~var_files ~vars with
       | Some name -> name
       | None -> workspace_name ())
  in
  (* The platform teardown, result-returning. The elevated bootstrap access is
     opened by the bracket ([reconcile_and_enable]) and removed by its cleanup,
     so this never threads an [on_error]: a failure returns, and the removal
     happens structurally (FND-0047). *)
  let destroy_platform_result ~cluster () : (unit, string) result =
    let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
    let platform_dir =
      workdir provider Sol_cli_platform_assets.Platform ~backend_config:platform_backend
    in
    let* platform_vars =
      platform_vars_of_result
        ~context:Sol_cli_cloud_lifecycle.Destruction
        ~cloud_target
        ~cluster
        ()
    in
    with_cluster_access_result cluster (fun ~env ->
      let* () =
        init_result
          ~assets
          run_log
          ~provider
          ~role:Sol_cli_platform_assets.Platform
          platform_backend
      in
      Sol_cli_platform_teardown.destroy
        ~run_log
        ~env
        ~chdir:platform_dir
        ~vars:platform_vars)
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
        (fun () ->
          init_result
            ~assets
            run_log
            ~provider
            ~role:Sol_cli_platform_assets.Cluster
            cloud_backend)
    ; observe_state =
        (fun () ->
          match Sol_cli_terraform.show_json ~chdir:infra_dir () with
          | Ok result ->
            state_ref := Sol_cli_cloud_destroy.inventory_of_show_json result.stdout;
            Ok result.stdout
          | Error (Sol_cli_process.Non_zero result) ->
            Error (Printf.sprintf "terraform show failed with exit %d" result.exit_code)
          | Error error ->
            Error
              ("could not read terraform state: " ^ Sol_cli_process.error_to_string error))
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
            destruction.prepare ~retention ~cluster_name:(prepare_cluster_name ()) ~state
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
            Error "the platform teardown requires install outputs, which are unavailable")
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
            ~vars:(vars @ Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:false))
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
            Sol_cli_report.app
              "  no provisioner role declared: no bootstrap elevation to verify";
            Ok ()
          | Some { bootstrap_window = Closed_by_platform_root; _ } -> Ok ()
          | None ->
            Sol_cli_report.app
              "  bootstrap window: not observed (no install outputs to reach the cluster \
               with)";
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
                     not be verified (%s). Proceeding: destroying the substrate removes \
                     the access with it, and teardown is not blocked by a probe that can \
                     fail (ADR 0003 invariant 6)."
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
    ; report = (fun message -> Sol_cli_report.app "%s" message)
    ; warn = (fun message -> Sol_cli_report.warn "%s" message)
    }
  in
  deps
;;
