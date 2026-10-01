type scope =
  | Workspace
  | Domain of string
  | Service of string * string
  | Resource of string * string

type kind =
  | Logs
  | Metrics
  | Dashboard
  | Infra

val parse_scope : string option -> (scope, string) result
val validate : kind:kind -> target_present:bool -> scope -> (unit, string) result
val requires_target : kind -> bool

val url
  :  base_url:string
  -> workspace:string
  -> kind:kind
  -> scope
  -> (string, string) result
