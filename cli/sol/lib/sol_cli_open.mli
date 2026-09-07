(* URL construction for 'sol open logs|metrics|dashboard' (OBS-010). *)

type scope =
  | Workspace
  | Domain of string
  | Service of string * string

type kind = Logs | Metrics | Dashboard

(** [parse_scope arg] parses the optional 'sol open' positional argument:
    [None] is workspace scope; ["domain"] is domain scope;
    ["domain/service"] is service scope. Anything else is an [Error]. *)
val parse_scope : string option -> (scope, string) result

(** [url ~base_url ~workspace ~kind scope] builds the Grafana URL for
    [kind] at [scope]:
    - [Logs] builds an Explore URL scoped by namespace (and service, when
      scoped to one).
    - [Metrics] and [Dashboard] both deep-link into OBS-011's provisioned
      dashboards (workspace overview, or the service template with
      $workspace/$domain/$service preset via query params once scoped;
      $workspace is always preset -- see OBS-020).
    [Error _] means [scope]'s domain/service name failed Sol's naming
    rules (see [Sol_cli_deployment_plan]). *)
val url
  :  base_url:string
  -> workspace:string
  -> kind:kind
  -> scope
  -> (string, string) result
