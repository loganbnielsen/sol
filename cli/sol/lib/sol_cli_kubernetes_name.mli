type k8s_name
type namespace

val validate_dns_label : string -> (unit, string) result

(** Validate an already-normalized Kubernetes object name. *)
val make_k8s_name : string -> (k8s_name, string) result

(** Validate an already-normalized Kubernetes namespace. *)
val make_namespace : string -> (namespace, string) result

(** Normalize a service source name, then validate it as a DNS label. *)
val k8s_name_of_source : string -> (k8s_name, string) result

(** Normalize workspace/domain parts, join them with ["-"], then validate. *)
val namespace_of_parts : workspace:string -> domain:string -> (namespace, string) result

(** Lowercase ASCII and map underscores to hyphens. *)
val normalize : string -> string

val k8s_name_to_string : k8s_name -> string
val namespace_to_string : namespace -> string

(** [sanitize_label_value v] produces a valid Kubernetes label value from any
    input: lowercases, replaces every character that isn't alphanumeric or [-]
    with [-] (a superset of [normalize]'s underscore-only handling), bounds to
    63 characters, and strips/fixes up leading/trailing non-alphanumeric
    characters. Unlike [validate_dns_label] this never errors -- a bad label
    value is far cheaper than a failed deploy. The single function
    [Sol_cli_manifest_yaml.render_taxonomy_labels] and
    [Sol_cli_open.dashboard_url] both call for workspace/domain, so a rendered
    label and a dashboard link's query param always agree for the same input. *)
val sanitize_label_value : string -> string

(** [sanitize_name v] produces a valid Kubernetes object *name* (an RFC 1123
    subdomain: lowercase alphanumerics, [-], [.], up to 253 characters, starting
    and ending alphanumerically) from any input. It is the stricter sibling of
    {!sanitize_label_value} — notably [_] is legal in a label value but not in
    a name, which is how a workspace like [ci_smoke] produced an invalid
    ["sol-deploy-state-ci_smoke"]. Use this whenever a workspace, domain or unit
    is embedded in [metadata.name]. *)
val sanitize_name : string -> string
