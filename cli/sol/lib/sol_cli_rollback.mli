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
val argo_plugin_available : unit -> bool

(** Execute the rollback for the given target. [Standard_deployment] calls
    [kubectl rollout undo] then [kubectl rollout status]. [Argo_rollout] calls
    [kubectl argo rollouts undo] if the plugin is available, or returns
    [Error (Plugin_missing _)] otherwise. [No_op] always returns [Ok ()]. *)
val execute_rollback : rollback_target -> (unit, error) result

val error_to_string : error -> string
