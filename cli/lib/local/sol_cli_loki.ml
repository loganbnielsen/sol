type credentials =
  { username : string
  ; password : string
  }

let query_range_argv_logql ~base_url ~logql ~limit ~timeout_s ?curl_config ()
  : string list
  =
  let auth_args =
    match curl_config with
    | None -> []
    | Some path -> [ "--config"; path ]
  in
  [ "curl"; "-sS"; "--max-time"; string_of_float timeout_s ]
  @ auth_args
  @ [ "-w"
    ; "\n%{http_code}"
    ; "--get"
    ; base_url ^ "/loki/api/v1/query_range"
    ; "--data-urlencode"
    ; "query=" ^ logql
    ; "--data-urlencode"
    ; "limit=" ^ string_of_int limit
    ; "--data-urlencode"
    ; "direction=backward"
    ]
;;

let query_range_argv ~base_url ~unit ~limit ~timeout_s ?curl_config () =
  query_range_argv_logql
    ~base_url
    ~logql:(Sol_cli_log_selector.unit unit)
    ~limit
    ~timeout_s
    ?curl_config
    ()
;;

type line =
  { ts_ns : string
  ; text : string
  }

let split_body_and_status (raw : string) : string * int option =
  match String.rindex_opt raw '\n' with
  | None -> raw, None
  | Some i ->
    let body = String.sub raw 0 i in
    let code_str = String.sub raw (i + 1) (String.length raw - i - 1) in
    body, int_of_string_opt (String.trim code_str)
;;

let parse_query_range_body (body : string) : (line list, string) result =
  let open Result.Syntax in
  let what = "Loki response" in
  let line = function
    | `List [ `String ts_ns; `String text ] -> Ok { ts_ns; text }
    | _ -> Error (what ^ ": a value is not a [timestamp, line] pair")
  in
  let stream_lines stream =
    let* values = Sol_cli_json.require ~what [ "values" ] Sol_cli_json.list stream in
    Sol_cli_result.map_list line values
  in
  let* json = Sol_cli_json.decode ~what body in
  match Sol_cli_json.field [ "status" ] json |> Sol_cli_json.string with
  | Some "success" ->
    let* streams =
      Sol_cli_json.require ~what [ "data"; "result" ] Sol_cli_json.list json
    in
    let* lines = Sol_cli_result.map_list stream_lines streams in
    Ok (List.concat lines |> List.sort (fun a b -> compare a.ts_ns b.ts_ns))
  | Some other -> Error (Printf.sprintf "Loki returned status %S" other)
  | None -> Error "Loki response had no status field"
;;

type fetch_error =
  | Timeout
  | Connection_failed
  | Http_error of int
  | Malformed of string
  | Other of string

let fetch_error_to_string = function
  | Timeout -> "query timed out"
  | Connection_failed -> "connection failed"
  | Http_error code -> Printf.sprintf "HTTP %d" code
  | Malformed msg -> msg
  | Other msg -> msg
;;

let classify_parse_result = function
  | Ok lines -> Ok lines
  | Error msg -> Error (Malformed msg)
;;

let classify_process_error (e : Sol_cli_process.error) : fetch_error =
  match e with
  | Sol_cli_process.Timeout _ -> Timeout
  | Sol_cli_process.Spawn_failed msg -> Other msg
  | Sol_cli_process.Non_zero { exit_code = 28; _ } -> Timeout
  | Sol_cli_process.Non_zero { exit_code = 6 | 7 | 56; _ } -> Connection_failed
  | Sol_cli_process.Non_zero { exit_code; stderr; stdout = _ } ->
    Other (Printf.sprintf "curl exit %d: %s" exit_code stderr)
;;

let resolve_credentials ~flag_username ~flag_password ~env_username ~env_password
  : (credentials option, string) result
  =
  let nonempty = function
    | None -> None
    | Some s ->
      let s = String.trim s in
      if s = "" then None else Some s
  in
  let pick flag env =
    match nonempty flag with
    | Some _ as v -> v
    | None -> nonempty env
  in
  match pick flag_username env_username, pick flag_password env_password with
  | None, None -> Ok None
  | Some username, Some password -> Ok (Some { username; password })
  | Some _, None ->
    Error
      "--loki-username (or SOL_LOKI_USERNAME) is set without a password -- pass \
       --loki-password or set SOL_LOKI_PASSWORD too"
  | None, Some _ ->
    Error
      "--loki-password (or SOL_LOKI_PASSWORD) is set without a username -- pass \
       --loki-username or set SOL_LOKI_USERNAME too"
;;

let curl_config_quote s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | '\\' -> Buffer.add_string buf "\\\\"
      | '"' -> Buffer.add_string buf "\\\""
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

let curl_auth_config { username; password } =
  "user = \"" ^ curl_config_quote (username ^ ":" ^ password) ^ "\"\n"
;;

let query_logql ~base_url ~logql ?credentials ?(limit = 100) ?(timeout_s = 5.0) ()
  : (line list, fetch_error) result
  =
  let with_curl_config f =
    match credentials with
    | None -> f None
    | Some credentials ->
      Sol_cli_fs.with_temp_file
        ~prefix:"sol-loki-curl-"
        ~suffix:".conf"
        (curl_auth_config credentials)
        (fun path -> f (Some path))
      |> Result.map_error (fun msg ->
        Other ("could not prepare Loki credentials: " ^ msg))
      |> Result.join
  in
  with_curl_config
  @@ fun curl_config ->
  let argv = query_range_argv_logql ~base_url ~logql ~limit ~timeout_s ?curl_config () in
  let redact =
    match credentials with
    | None -> []
    | Some { password; _ } -> [ password ]
  in
  match
    Sol_cli_process.run (Sol_cli_process.cmd ~timeout_s:(timeout_s +. 2.0) ~redact argv)
  with
  | Error e -> Error (classify_process_error e)
  | Ok r ->
    let body, code = split_body_and_status r.stdout in
    (match code with
     | Some c when c < 200 || c >= 300 -> Error (Http_error c)
     | _ -> classify_parse_result (parse_query_range_body body))
;;

let query ~base_url ~unit ?credentials ?limit ?timeout_s () =
  query_logql
    ~base_url
    ~logql:(Sol_cli_log_selector.unit unit)
    ?credentials
    ?limit
    ?timeout_s
    ()
;;
