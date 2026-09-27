type t =
  { context : string
  ; kubeconfig : string option
  }

val to_string : t -> string
val of_context : ?kubeconfig:string -> string -> (t, string) result
val local : t
val kubectl_args : t -> string list
val helm_args : t -> string list
val environment : t -> (string * string) list

type context = { destination : t }

val context_of_destination : t -> context
val local_context : context
val kubectl_context_args : context -> string list
val helm_context_args : context -> string list
val context_environment : context -> (string * string) list
val context_to_string : context -> string
val child_environment : context -> string array
