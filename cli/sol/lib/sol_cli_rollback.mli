type rollback_target =
  | Standard_deployment of
      { namespace : string
      ; name : string
      }
  | Argo_rollout of
      { namespace : string
      ; name : string
      }
  | No_op of string

type error =
  | Kubectl_error of Sol_cli_process.error
  | Plugin_missing of
      { namespace : string
      ; name : string
      }
  | Non_zero of
      { command : string
      ; exit_code : int
      }

(** Derive a [rollback_target] from a resolved service spec. [Fn] primitives
    produce [No_op] because CronJobs do not support rollout history. Services
    with [progressive_delivery] set produce [Argo_rollout]. All others produce
    [Standard_deployment]. *)
val rollback_target_of_service : Sol_cli_deployment_plan.service_spec -> rollback_target

(** Return [true] when the kubectl-argo-rollouts plugin is reachable via
    [kubectl-argo-rollouts version] or [kubectl argo rollouts version]. *)
val argo_plugin_available : ctx:Sol_cli_kube_destination.context -> unit -> bool

(** Execute the rollback for the given target in the cluster [ctx] names.
    [Standard_deployment] calls [kubectl rollout undo] then [kubectl rollout
    status]. [Argo_rollout] calls [kubectl argo rollouts undo] if the plugin is
    available, or returns [Error (Plugin_missing _)] otherwise. [No_op] always
    returns [Ok ()]. *)
val execute_rollback
  :  ctx:Sol_cli_kube_destination.context
  -> rollback_target
  -> (unit, error) result

val error_to_string : error -> string

(** [service_specs_of_release release] reconstructs the resolved
    [service_spec] list a deploy of [release] would have produced (FEAT-066).

    This is a historical decode, not a planner: it depends exclusively on data
    reachable from [release] plus pure deterministic helpers ([k8s_name_result],
    [namespace_result], [service_url], [call_env_var], and the canonical
    inverse decoders in {!Sol_cli_toml}) — never the workspace, [sol.toml]/
    [sol.yml], the current environment, discovery, or current cluster state.

    [called_by] is not a field of the stored record; it is derived purely from
    every workload's own [calls] rows (matching by target namespace/name), using
    the same [call_env_var] helper the forward planner uses. Reusing a stored
    forward-edge env var here would preserve most of the call graph while
    silently changing NetworkPolicy output.

    Decode failures name the release, the workload and the offending fact —
    e.g. ["cannot reconstruct release r-x: workload payments has an invalid
    progressive delivery \"canary:bogus\""] — before any render or mutation, so
    a corrupt historical artifact is distinguishable from a cluster refusing a
    valid restoration. *)
val service_specs_of_release
  :  Sol_cli_release.t
  -> (Sol_cli_deployment_plan.service_spec list, string) result
