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
