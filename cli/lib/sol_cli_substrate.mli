(* The workspace execution substrate: the cluster-scoped scaffolding an operation
   needs before it can act on a workspace. See the implementation for why this is
   a layer of its own and not part of the workload render (HARDEN-002 run 2,
   finding 8). *)

(** The distinct application namespaces this plan's workloads live in, in a stable
    order. *)
val namespaces : Sol_cli_deployment_plan.t -> string list

(** The YAML documents that establish the workspace substrate, in apply order:
    every namespace, then each namespace's runtime Secret.

    [secrets] defaults to the runtime Secret's keys ([Sol_cli_manifest]);
    a declared key that is not present in the environment is an error rather than
    an empty credential. *)
val docs
  :  ?secrets:(string * string) list
  -> Sol_cli_deployment_plan.t
  -> (string list, string) result

(** As {!docs}, for an explicit namespace list. *)
val docs_for_namespaces
  :  ?secrets:(string * string) list
  -> string list
  -> (string list, string) result

(** Establish the substrate against a cluster, idempotently. Fails closed, without
    applying anything, when a required secret value is missing from the
    environment. *)
val ensure
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> (unit, string) result

(** DEC-038 §6 / INFRA-058: the operator RoleBinding documents for every namespace
    holding a Sol-managed workload, derived from the workspace's service inventory
    rather than from any command's scope. Pure: it produces RoleBindings and
    nothing else. *)
val operator_binding_docs
  :  workspace:string
  -> Sol_cli_manifest.service list
  -> string list

(** [reconcile_operator_bindings ~ctx ~workspace] establishes the operator's
    read-only diagnostic grant in every workload namespace, independent of whether
    that namespace participated in the current operation.

    RBAC only: it must not write runtime Secrets and must not apply workload
    documents, which is why it does not go through {!ensure}. Safe to run
    repeatedly, and it is what makes an already-running workload diagnosable
    without redeploying it. *)
val reconcile_operator_bindings
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (unit, string) result
