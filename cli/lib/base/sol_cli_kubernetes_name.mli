type k8s_name
type namespace

val validate_dns_label : string -> (unit, string) result
val make_k8s_name : string -> (k8s_name, string) result
val make_namespace : string -> (namespace, string) result
val k8s_name_of_source : string -> (k8s_name, string) result
val namespace_of_parts : workspace:string -> domain:string -> (namespace, string) result
val normalize : string -> string
val k8s_name_to_string : k8s_name -> string
val namespace_to_string : namespace -> string
val sanitize_label_value : string -> string
val sanitize_name : string -> string
val service_url : namespace:namespace -> k8s_name:k8s_name -> string
val call_env_var : string -> string
