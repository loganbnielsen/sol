val build :
  tag:string ->
  dockerfile:string ->
  context:string ->
  (unit, Sol_cli_process.error) result

val push : image_ref:string -> (unit, Sol_cli_process.error) result
val inspect_digest : image_ref:string -> string
