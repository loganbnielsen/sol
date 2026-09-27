type context =
  { cluster : Sol_cli_kube_destination.context
  ; workspace : string
  ; env : string option
  }

val context
  :  cluster:Sol_cli_kube_destination.context
  -> workspace:string
  -> ?env:string
  -> unit
  -> context
