type line =
  { ts_ns : string
  ; text : string
  }

type credentials =
  { username : string
  ; password : string
  }

val query_range_argv
  :  base_url:string
  -> unit:Sol_cli_log_selector.t
  -> limit:int
  -> timeout_s:float
  -> ?curl_config:string
  -> unit
  -> string list

val query_range_argv_logql
  :  base_url:string
  -> logql:string
  -> limit:int
  -> timeout_s:float
  -> ?curl_config:string
  -> unit
  -> string list

val split_body_and_status : string -> string * int option
val parse_query_range_body : string -> (line list, string) result

type fetch_error =
  | Timeout
  | Connection_failed
  | Http_error of int
  | Malformed of string
  | Other of string

val fetch_error_to_string : fetch_error -> string
val classify_process_error : Sol_cli_process.error -> fetch_error
val classify_parse_result : (line list, string) result -> (line list, fetch_error) result

val resolve_credentials
  :  flag_username:string option
  -> flag_password:string option
  -> env_username:string option
  -> env_password:string option
  -> (credentials option, string) result

val query
  :  base_url:string
  -> unit:Sol_cli_log_selector.t
  -> ?credentials:credentials
  -> ?limit:int
  -> ?timeout_s:float
  -> unit
  -> (line list, fetch_error) result

val query_logql
  :  base_url:string
  -> logql:string
  -> ?credentials:credentials
  -> ?limit:int
  -> ?timeout_s:float
  -> unit
  -> (line list, fetch_error) result
