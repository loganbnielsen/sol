type backend =
  | Local
  | Self_hosted_durable
  | External

val backend_of_string : string -> backend option
val backend_to_string : backend -> string
