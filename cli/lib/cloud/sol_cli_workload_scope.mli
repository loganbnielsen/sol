type scope =
  { namespace : string
  ; workloads : string list
  }

val list_workloads_args : namespace:string -> string list

val delete_args
  :  namespace:string
  -> names:string list
  -> timeout_seconds:int
  -> string list

val wait_args : namespace:string -> workspace:string -> timeout_seconds:int -> string list
val workloads_of_json : string -> workspace:string -> (string list, string) result
val to_string : scope -> string
