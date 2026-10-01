type scope =
  { namespace : string
  ; workloads : string list
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
val workloads_of_json : string -> workspace:string -> (string list, string) result
val to_string : scope -> string
