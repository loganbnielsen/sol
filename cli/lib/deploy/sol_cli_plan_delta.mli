type delta =
  | Deferred of string
  | Delta of
      { declared :
          (Sol_cli_workload_ownership.identity * Sol_cli_workload_ownership.declared) list
      ; surplus :
          (Sol_cli_workload_ownership.identity * Sol_cli_workload_ownership.surplus) list
      ; unobservable : (string * string) list
      }

val compute
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> evidence:(Sol_cli_release_id.owned_object list, string) result
  -> declared:Sol_cli_workload_ownership.identity list
  -> delta

val to_string : delta -> string
