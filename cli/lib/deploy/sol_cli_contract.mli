type mode =
  | Check
  | Apply

val run
  :  workspace:string
  -> registry_url:string
  -> mode:mode
  -> (string option, string) result

val has_projection : workspace:string -> bool
val report : workspace:string -> registry_url:string -> mode:mode -> (unit, string) result
