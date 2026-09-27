type verdict =
  | Proceed
  | Warn of string
  | Acknowledge of string
  | Refuse of string

val verdict
  :  constructive:bool
  -> accept_unresolved:bool
  -> Sol_cli_supervised.status
  -> verdict

val check
  :  constructive:bool
  -> accept_unresolved:bool
  -> chdir:string
  -> backend_config:string list
  -> (unit, string) result
