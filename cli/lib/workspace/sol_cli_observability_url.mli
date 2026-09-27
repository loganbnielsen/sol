type backend =
  | Local
  | Self_hosted_durable
  | External

val backend_of_string : string -> backend option
val backend_to_string : backend -> string

type resolution =
  | Url of string
  | No_url of string

val resolve
  :  backend:backend
  -> ?base_domain:string
  -> ?override:string
  -> unit
  -> resolution

val effective_backend_and_base_domain
  :  explicit_backend:backend option
  -> explicit_base_domain:string option
  -> target:string option
  -> unit
  -> (backend * string option, string) result
