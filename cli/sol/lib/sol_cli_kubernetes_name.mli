type k8s_name
type namespace

val validate_dns_label : string -> (unit, string) result
val make_k8s_name : string -> (k8s_name, string) result
(** Validate an already-normalized Kubernetes object name. *)

val make_namespace : string -> (namespace, string) result
(** Validate an already-normalized Kubernetes namespace. *)

val k8s_name_of_source : string -> (k8s_name, string) result
(** Normalize a service source name, then validate it as a DNS label. *)

val namespace_of_parts : workspace:string -> domain:string -> (namespace, string) result
(** Normalize workspace/domain parts, join them with ["-"], then validate. *)

val normalize : string -> string
(** Lowercase ASCII and map underscores to hyphens. *)

val k8s_name_to_string : k8s_name -> string
val namespace_to_string : namespace -> string

(** [sanitize_label_value v] produces a valid Kubernetes label value from
    any input: lowercases, replaces every character that isn't
    alphanumeric or [-] with [-] (a superset of [normalize]'s
    underscore-only handling), bounds to 63 characters, and strips/fixes
    up leading/trailing non-alphanumeric characters. Unlike
    [validate_dns_label] this never errors -- a bad label value is far
    cheaper than a failed deploy. The single function
    [Sol_cli_manifest_yaml.render_taxonomy_labels] and
    [Sol_cli_open.dashboard_url] both call for workspace/domain, so a
    rendered label and a dashboard link's query param always agree for
    the same input. *)
val sanitize_label_value : string -> string
