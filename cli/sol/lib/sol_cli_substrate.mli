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
