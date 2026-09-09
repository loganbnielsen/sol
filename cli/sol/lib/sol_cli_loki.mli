(* Minimal Loki query client for 'sol logs'. Shells out to curl rather than
   adding an HTTP library, matching how this CLI already wraps
   kubectl/docker/helm/terraform. *)

type line = { ts_ns : string; text : string }

type credentials = { username : string; password : string }
(** Basic-auth credentials for a Loki query request, e.g. a Grafana Cloud
    stack's instance ID + API key -- the same shape as
    cli/platform/infra/base/main.tf's external_loki_username/password for the
    write side. *)

val query_range_argv :
  base_url:string ->
  ns:string ->
  k8s_name:string ->
  limit:int ->
  timeout_s:float ->
  ?curl_config:string ->
  unit ->
  string list
(** Build the curl argv for a Loki range query over
    [{namespace="<ns>",app="<k8s_name>"}], adding [--config <path>] when
    [curl_config] is given. The config file may contain credentials, so only its
    path is present in argv. Exposed for testing. *)

val split_body_and_status : string -> string * int option
(** Split curl's ["<body>\n<http_code>"] output (produced by
    [-w '\n%{http_code}']) back into the body and the parsed status code. *)

val parse_query_range_body : string -> (line list, string) result
(** Parse a Loki [/loki/api/v1/query_range] JSON response body into log lines,
    oldest first. *)

type fetch_error =
  | Timeout
  | Connection_failed
  | Http_error of int
  | Other of string

val fetch_error_to_string : fetch_error -> string

val classify_process_error : Sol_cli_process.error -> fetch_error
(** Classify a [Sol_cli_process] failure from running curl into a [fetch_error],
    distinguishing timeouts and connection failures from other curl errors. *)

val resolve_credentials :
  flag_username:string option ->
  flag_password:string option ->
  env_username:string option ->
  env_password:string option ->
  (credentials option, string) result
(** [resolve_credentials ~flag_username ~flag_password ~env_username
     ~env_password] resolves Loki basic-auth credentials from an explicit
    [--loki-username]/[--loki-password] flag pair and the
    [SOL_LOKI_USERNAME]/[SOL_LOKI_PASSWORD] environment variables, flag winning
    over env var field-by-field. [Error] when exactly one of username/password
    ends up set -- Loki basic auth needs both together. Empty or whitespace-only
    values count as unset. [Ok None] when neither is set: existing
    unauthenticated behavior. *)

val query :
  base_url:string ->
  ns:string ->
  k8s_name:string ->
  ?credentials:credentials ->
  ?limit:int ->
  ?timeout_s:float ->
  unit ->
  (line list, fetch_error) result
(** Query Loki for recent log lines for a service, authenticating with
    [credentials] (HTTP Basic auth) when given. Returns [Ok []] when the query
    succeeds but finds nothing (a legitimate state, e.g. no pod-level log
    shipping configured yet — not treated as a Loki failure). *)
