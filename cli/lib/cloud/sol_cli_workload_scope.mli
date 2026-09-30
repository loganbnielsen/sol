type scope =
  { namespace : string
  ; pods : string list
  }

val selector : workspace:string -> string
val list_args : namespace:string -> workspace:string -> string list

val delete_args
  :  namespace:string
  -> workspace:string
  -> timeout_seconds:int
  -> string list

val wait_args : namespace:string -> workspace:string -> timeout_seconds:int -> string list
val pods_of_pods_json : string -> (string list, string) result
val to_string : scope -> string
