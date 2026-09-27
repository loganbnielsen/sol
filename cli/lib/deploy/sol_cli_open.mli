type scope =
  | Workspace
  | Domain of string
  | Service of string * string
  | Resource of string * string

type kind =
  | Logs
  | Metrics
  | Dashboard

val parse_scope : string option -> (scope, string) result

val url
  :  base_url:string
  -> workspace:string
  -> kind:kind
  -> scope
  -> (string, string) result
