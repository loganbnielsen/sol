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
    namespace's runtime Secret.

    Creating a namespace is not workload mutation, so applying these before the
    migration gate does not weaken AUDIT-069's invariant. *)
let docs_for_namespaces ?secrets namespaces : (string list, string) result =
  match secret_docs ?secrets namespaces with
  | Error _ as e -> e
  | Ok secret_docs ->
    Ok (List.map (fun ns -> Sol_cli_manifest.namespace_doc ~ns) namespaces @ secret_docs)
;;

let docs ?secrets (plan : Sol_cli_deployment_plan.t) : (string list, string) result =
  docs_for_namespaces ?secrets (namespaces plan)
;;

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

(** [ensure ~ctx ~namespaces] establishes the substrate against [ctx] if it is not
    already there. Idempotent ([kubectl apply] of a namespace and a Secret).

    Returns [Error] rather than proceeding when a required secret value is
    missing, so an operation that needs the substrate fails closed before it
    reaches the thing the substrate was needed for. *)
let ensure ~ctx ~namespaces : (unit, string) result =
  match docs_for_namespaces namespaces with
  | Error _ as e -> e
  | Ok docs ->
    let rec apply_all = function
      | [] -> Ok ()
      | doc :: rest ->
        let path = Filename.temp_file "sol-substrate-" ".yaml" in
        write_file path doc;
        (match Sol_cli_kubectl.apply ~ctx ~file:path with
         | Ok () -> apply_all rest
         | Error err ->
           Error
             (Printf.sprintf
                "kubectl apply (workspace substrate): %s"
                (Sol_cli_process.error_to_string err)))
    in
    apply_all docs
;;
