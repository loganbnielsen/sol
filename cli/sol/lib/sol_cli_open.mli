(* URL construction for 'sol open logs|metrics|dashboard' (OBS-010). *)

type scope =
  | Workspace
  | Domain of string
  | Service of string * string
  | Resource of string * string
  (** [Resource (resource_type, resource_name)] -- a managed infrastructure
      resource dashboard (OBS-044), e.g. an RDS instance. Generic over
      [resource_type]: the CLI never validates it against a known list,
      matching platform/infra's generic-by-resource-type Terraform shape. *)

type kind = Logs | Metrics | Dashboard

(** [parse_scope arg] parses the optional 'sol open' positional argument:
    [None] is workspace scope; ["domain"] is domain scope;
    ["domain/service"] is service scope; ["resource/<type>/<name>"] is a
    managed resource dashboard scope (OBS-044). Anything else is an
    [Error]. *)
val parse_scope : string option -> (scope, string) result

(** [url ~base_url ~workspace ~kind scope] builds the Grafana URL for
    [kind] at [scope]:
    - [Logs] builds an Explore URL scoped by namespace (and service, when
      scoped to one); [Resource] scope has no logs view ([Error]) --
      managed resources don't ship through Sol's Loki pipeline.
    - [Metrics] and [Dashboard] both deep-link into OBS-011's provisioned
      dashboards (workspace overview, or the service template with
      $workspace/$domain/$service preset via query params once scoped;
      $workspace is always preset -- see OBS-020) -- except [Resource]
      scope, which deep-links into the OBS-044 managed-resource dashboard
      (platform/infra/base's dashboards/managed-resource.json.tftpl,
      keyed by [resource_type]) with a preset $resource query param.
    [Error _] means [scope]'s domain/service/resource name failed Sol's
    naming rules (see [Sol_cli_deployment_plan]), or (for [Logs] +
    [Resource]) that no logs view exists for managed resources. *)
val url
  :  base_url:string
  -> workspace:string
  -> kind:kind
  -> scope
  -> (string, string) result
