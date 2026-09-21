(* The workspace execution substrate.

   HARDEN-002 run 2, finding 8: a freshly provisioned production target could not
   run its first deploy. The migration gate (AUDIT-069) runs before workload
   mutation, and it needs two things that only workload mutation created:

     - the application namespace, and
     - the runtime Secret ([sol-secrets], which carries POSTGRES_URL).

   So [sol deploy] failed closed and prescribed [sol migrate apply], which failed
   with the identical error -- the gate required artifacts owned behind the gate.

   The ordering itself is right: verifying the schema before mutating workloads is
   the invariant, and creating [namespace/pluto] is not deploying [charge_svc].
   What was wrong is that namespace and Secret creation were assigned to the
   *workload* lifecycle layer, where they sit behind the gate that needs them.

   This module makes that layer explicit. The substrate is the cluster-scoped
   scaffolding an operation needs before it can act on a workspace, and it is
   established by whatever operation needs it -- [sol migrate apply],
   [sol migrate status], the deploy migration verification, [sol deploy] -- rather
   than being a special case inside one of them.

   It is deliberately narrow: the namespace and the workspace's runtime Secret.
   Workload desired state (Deployments, Services, PDBs, probes, ...) stays where it
   belongs, in the workload render, behind the migration gate. *)

(* INFRA-025 residual: Kubernetes RBAC has no "except this namespace" rule.
   sol-deploy-bootstrap's `rolebindings: create` must be granted cluster-wide
   (RoleBinding creation cannot be restricted by namespace or by resourceNames
   -- resourceNames is not honored for `create` at all, per the Kubernetes API
   itself, and there is no partial-cluster-scope ClusterRoleBinding), so RBAC
   alone cannot stop the deploy identity from creating a `sol-deploy`
   RoleBinding directly inside a platform namespace it should never reach.
   Closing that fully needs an admission-control layer (ValidatingAdmissionPolicy
   or similar) Sol does not have yet -- tracked as a follow-up, not invented
   here. This list is the software-side guard in the meantime: every ordinary
   path into this module (sol deploy, sol migrate apply) refuses a namespace
   name that collides with a platform one, mirroring DEC-016's reservation of
   "local" as an environment name. It stops accidental collision through Sol's
   own CLI; it is not a substitute for the missing admission-control layer
   against a deliberately malicious holder of the deploy credential -- see
   INFRA-025's completion notes for the accepted threat model. *)
let reserved_platform_namespaces =
  [ "cert-manager"; "ingress-nginx"; "argocd"; "redpanda"; "monitoring"; "postgresql" ]
;;

let namespaces (plan : Sol_cli_deployment_plan.t) : string list =
  plan.Sol_cli_deployment_plan.services
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Sol_cli_deployment_plan.namespace_to_string spec.namespace)
  |> List.sort_uniq String.compare
;;

let value_from_env key =
  match Sys.getenv_opt key with
  | Some value -> value
  | None -> ""
;;

(* Same content as the workload render's runtime Secret, so establishing the
   substrate early and rendering the workload bundle later agree. A key that is
   declared but not present in the environment fails closed rather than being
   established empty: the migration gate cannot verify anything through a Secret
   with no connection string, and silently empty credentials are worse than a
   refusal. *)
let secret_docs ?(secrets = Sol_cli_manifest.default_secrets) namespaces =
  let missing =
    List.filter_map
      (fun (key, _) ->
         match Sys.getenv_opt key with
         | Some _ -> None
         | None -> Some key)
      secrets
  in
  match missing with
  | first :: _ ->
    Error
      (Printf.sprintf
         "required secret env var(s) not set: %s. The workspace substrate (its runtime \
          Secret) cannot be established without them, and every workspace-scoped \
          operation -- migrations included -- needs it."
         first)
  | [] ->
    Ok
      (List.map
         (fun ns ->
            Sol_cli_manifest.secret_doc
              ~base_secrets:(List.map (fun (k, _) -> k, value_from_env k) secrets)
              ~ns
              ~name:Sol_cli_manifest.runtime_secret_name
              ())
         namespaces)
;;

(** The YAML documents that establish the workspace substrate for [namespaces],
    in the order they must be applied: every namespace first, then each
    namespace's deploy-identity RoleBinding (INFRA-025), then each namespace's
    runtime Secret.

    Creating a namespace is not workload mutation, so applying these before the
    migration gate does not weaken AUDIT-069's invariant. The RoleBinding is
    likewise not workload mutation -- it grants the deploy identity (not any
    workload) permission to act in this namespace, established once alongside
    the namespace itself rather than as a side effect of the first deploy. *)
let docs_for_namespaces ?secrets namespaces : (string list, string) result =
  match secret_docs ?secrets namespaces with
  | Error _ as e -> e
  | Ok secret_docs ->
    Ok
      (List.map (fun ns -> Sol_cli_manifest.namespace_doc ~ns) namespaces
       @ List.map (fun ns -> Sol_cli_manifest.deploy_role_binding_doc ~ns) namespaces
       @ List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns) namespaces
       @ secret_docs)
;;

let docs ?secrets (plan : Sol_cli_deployment_plan.t) : (string list, string) result =
  docs_for_namespaces ?secrets (namespaces plan)
;;

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

(* INFRA-025: the deploy identity's namespace-bootstrap grant is deliberately
   create-only (see cli/platform/infra/base/platform_deploy_rbac.tf's
   sol-deploy-bootstrap ClusterRole) -- it can never patch/update a namespace
   or RoleBinding that already exists, including every platform one. So
   idempotency here comes from tolerating "AlreadyExists" on [create], not
   from [kubectl apply]'s patch, which this identity does not have for either
   kind.

   INFRA-048: the primitive lives in Sol_cli_manifest so the manifest apply path
   uses exactly the same one -- that path was applying the namespace, which is
   the defect this sharing removes. *)
let create_idempotent = Sol_cli_manifest.create_idempotent

let write_doc_to_temp_file doc =
  let path = Filename.temp_file "sol-substrate-" ".yaml" in
  write_file path doc;
  path
;;

let create_doc ~ctx doc =
  create_idempotent ~ctx ~file:(write_doc_to_temp_file doc)
  |> Result.map_error (Printf.sprintf "kubectl create (workspace substrate): %s")
;;

let apply_doc ~ctx doc =
  Sol_cli_kubectl.apply ~ctx ~file:(write_doc_to_temp_file doc)
  |> Result.map_error (fun err ->
    Printf.sprintf
      "kubectl apply (workspace substrate): %s"
      (Sol_cli_process.error_to_string err))
;;

(** [ensure ~ctx ~namespaces] establishes the substrate against [ctx] if it is not
    already there: every namespace and its deploy-identity RoleBinding
    (create, idempotent via "AlreadyExists" tolerance -- this identity cannot
    patch either kind), then each namespace's runtime Secret (apply, which
    the deploy identity's own namespace-scoped RoleBinding, just created,
    grants patch on).

    Returns [Error] rather than proceeding when a required secret value is
    missing, so an operation that needs the substrate fails closed before it
    reaches the thing the substrate was needed for. Also refuses a namespace
    that collides with a platform namespace ({!reserved_platform_namespaces}) --
    see that value's comment for why this check exists at all. *)
let ensure ~ctx ~namespaces : (unit, string) result =
  let ( let* ) = Result.bind in
  match List.find_opt (fun ns -> List.mem ns reserved_platform_namespaces) namespaces with
  | Some ns ->
    Error
      (Printf.sprintf
         "%s is a reserved platform namespace; no workspace may deploy into it"
         ns)
  | None ->
    let rec create_all = function
      | [] -> Ok ()
      | doc :: rest ->
        let* () = create_doc ~ctx doc in
        create_all rest
    in
    let rec apply_all = function
      | [] -> Ok ()
      | doc :: rest ->
        let* () = apply_doc ~ctx doc in
        apply_all rest
    in
    let* () =
      create_all (List.map (fun ns -> Sol_cli_manifest.namespace_doc ~ns) namespaces)
    in
    let* () =
      create_all
        (List.map (fun ns -> Sol_cli_manifest.deploy_role_binding_doc ~ns) namespaces
         @ List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns) namespaces
        )
    in
    (match secret_docs namespaces with
     | Error _ as e -> e
     | Ok docs -> apply_all docs)
;;

(* DEC-038 §6 / INFRA-058: the operator's read-only grant follows the *workload*,
   not the command that happens to be running.

   [ensure] above establishes the binding only for the namespaces the invoking
   command is operating on. So a namespace that has not taken part in a
   deploy/migrate since the grant existed never receives it, and the operator
   cannot diagnose the workload there -- while the only existing path that would
   create it redeploys the workload, which is the one thing establishing read
   authorization must never require.

   [operator_binding_docs] therefore enumerates every namespace holding a
   Sol-managed workload, from the workspace's own service inventory rather than
   from a command's scope. [reconcile_operator_bindings] applies them.

   RBAC only, deliberately: it does not call [ensure], because that path also
   writes each namespace's runtime Secret. Running a Secret write to fix a
   permission would be the wrong abstraction and a hazard. Nothing here touches a
   workload or a Secret -- the documents produced are RoleBindings and nothing
   else.

   [create] with AlreadyExists tolerated rather than [apply]: the deploy identity's
   bootstrap grant holds get/list/watch/create on rolebindings but not patch, so an
   apply would silently become a patch as soon as the object exists (INFRA-048). *)
let operator_binding_docs ~workspace (services : Sol_cli_manifest.service list)
  : string list
  =
  services
  |> List.filter_map (fun (s : Sol_cli_manifest.service) ->
    match
      Sol_cli_deployment_plan.namespace_result
        ~workspace
        ~domain:s.Sol_cli_manifest.domain
    with
    | Ok ns -> Some (Sol_cli_deployment_plan.namespace_to_string ns)
    | Error _ -> None)
  |> List.sort_uniq String.compare
  |> List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns)
;;

let reconcile_operator_bindings ~ctx ~workspace : (unit, string) result =
  let ( let* ) = Result.bind in
  let rec create_all = function
    | [] -> Ok ()
    | doc :: rest ->
      let* () = create_doc ~ctx doc in
      create_all rest
  in
  create_all (operator_binding_docs ~workspace (Sol_cli_manifest.discover_services ()))
;;
