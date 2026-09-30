type scope = { namespaces : string list }

val selector : workspace:string -> string
val list_args : workspace:string -> string list
val delete_namespace_args : namespace:string -> timeout_seconds:int -> string list
val namespaces_of_pods_json : string -> (string list, string) result
val to_string : scope -> string
