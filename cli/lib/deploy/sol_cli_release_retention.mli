val default_keep : int

type previous_release =
  | Known of string
  | None_yet
  | Unreadable of string

val select
  :  keep:int
  -> current:string
  -> previous:previous_release
  -> (string * string) list
  -> (string list, string) result

val prune
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> keep:int
  -> current:string
  -> previous:previous_release
  -> (string list, string) result

val enumerability_of_can_i_output : string -> bool option
val can_enumerate : ctx:Sol_cli_kube_destination.context -> bool option

type outcome =
  | Pruned of string list
  | Deferred of string
  | Failed of string

val with_retention
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> keep:int
  -> current:string
  -> previous:previous_release
  -> outcome
