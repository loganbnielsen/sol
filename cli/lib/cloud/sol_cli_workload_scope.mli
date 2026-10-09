type workload =
  { resource : string
  ; name : string
  ; uid : string
  }

type scope =
  { namespace : string
  ; workloads : workload list
  }

type workload_kind

val kinds : workload_kind list
val optional_kind : workload_kind -> bool
val resource_of_kind : workload_kind -> string
val list_args : namespace:string -> kind:workload_kind -> string list

val delete_args
  :  namespace:string
  -> names:string list
  -> timeout_seconds:int
  -> string list

val wait_args : namespace:string -> workspace:string -> timeout_seconds:int -> string list
val workloads_of_json : string -> workspace:string -> (workload list, string) result
val workload_to_string : workload -> string

val partition_owned
  :  evidence:Sol_cli_release_id.owned_object list
  -> scope
  -> workload list * workload list

val to_string : scope -> string

type release_failure =
  { namespace : string
  ; kind : string option
  ; operation : string
  ; reason : string
  }

type release =
  | Workloads_released
  | Workloads_not_releasable of string
  | Workloads_unestablished of release_failure

val failure_to_string : release_failure -> string

type read_error =
  | No_cluster of string
  | Read_unestablished of release_failure

val read_workloads
  :  run:(string list -> (string, Sol_cli_process.error) result)
  -> namespaces:string list
  -> workspace:string
  -> (scope list, read_error) result

val release_workloads
  :  run:(string list -> (string, Sol_cli_process.error) result)
  -> delete:
       (namespace:string -> names:string list -> (unit, Sol_cli_process.error) result)
  -> wait:(namespace:string -> (unit, Sol_cli_process.error) result)
  -> evidence:Sol_cli_release_id.owned_object list
  -> namespaces:string list
  -> workspace:string
  -> release
