val qualified_receiver_types : string list
val receiver_type_qualified : string -> bool
val url_is_routable : string -> bool

val validate
  :  receiver_type:string option
  -> receiver_url:string option
  -> owner:string option
  -> runbook_url:string option
  -> (unit, string) result
