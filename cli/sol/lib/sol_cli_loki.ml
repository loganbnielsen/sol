(* Minimal Loki query client for 'sol logs'. Shells out to curl — same
   pattern this CLI already uses for kubectl/docker/helm/terraform — rather
   than pulling in an HTTP library for one blocking GET. *)

module U = Yojson.Safe.Util

type credentials = { username : string; password : string }

let query_range_argv ~base_url ~ns ~k8s_name ~limit ~timeout_s ?curl_config () :
    string list =
  let logql = Printf.sprintf {|{namespace="%s",app="%s"}|} ns k8s_name in
  let auth_args =
    match curl_config with None -> [] | Some path -> [ "--config"; path ]
  in
  [ "curl"; "-sS"; "--max-time"; string_of_float timeout_s ]
  @ auth_args
  @ [
      "-w";
      "\n%{http_code}";
      "--get";
      base_url ^ "/loki/api/v1/query_range";
      "--data-urlencode";
      "query=" ^ logql;
      "--data-urlencode";
      "limit=" ^ string_of_int limit;
      "--data-urlencode";
      "direction=backward";
    ]

type line = { ts_ns : string; text : string }

(* curl's -w '\n%{http_code}' appends the status code as a final line after
   the response body; split it back off. *)
let split_body_and_status (raw : string) : string * int option =
  match String.rindex_opt raw '\n' with
  | None -> (raw, None)
  | Some i ->
      let body = String.sub raw 0 i in
      let code_str = String.sub raw (i + 1) (String.length raw - i - 1) in
      (body, int_of_string_opt (String.trim code_str))

let parse_query_range_body (body : string) : (line list, string) result =
  try
    let json = Yojson.Safe.from_string body in
    match U.member "status" json |> U.to_string_option with
    | Some "success" ->
        let streams =
          try U.member "data" json |> U.member "result" |> U.to_list
          with _ -> []
        in
        let lines =
          List.concat_map
            (fun stream ->
              try
                U.member "values" stream |> U.to_list
                |> List.filter_map (fun v ->
                    match v with
                    | `List [ `String ts_ns; `String text ] ->
                        Some { ts_ns; text }
                    | _ -> None)
              with _ -> [])
            streams
        in
        Ok (List.sort (fun a b -> compare a.ts_ns b.ts_ns) lines)
    | Some other -> Error (Printf.sprintf "Loki returned status %S" other)
    | None -> Error "Loki response had no status field"
  with
  | Yojson.Json_error msg ->
      Error (Printf.sprintf "could not parse Loki response: %s" msg)
  | exn ->
      Error
        (Printf.sprintf "could not parse Loki response: %s"
           (Printexc.to_string exn))

type fetch_error =
  | Timeout
  | Connection_failed
  | Http_error of int
  | Other of string

let fetch_error_to_string = function
  | Timeout -> "query timed out"
  | Connection_failed -> "connection failed"
  | Http_error code -> Printf.sprintf "HTTP %d" code
  | Other msg -> msg

(* curl exit codes: 28 = operation timeout, 6/7/56 = couldn't resolve/connect/receive. *)
let classify_process_error (e : Sol_cli_process.error) : fetch_error =
  match e with
  | Sol_cli_process.Timeout _ -> Timeout
  | Sol_cli_process.Spawn_failed msg -> Other msg
  | Sol_cli_process.Non_zero { exit_code = 28; _ } -> Timeout
  | Sol_cli_process.Non_zero { exit_code = 6 | 7 | 56; _ } -> Connection_failed
  | Sol_cli_process.Non_zero { exit_code; stderr } ->
      Other (Printf.sprintf "curl exit %d: %s" exit_code stderr)

(* OBS-032: resolves the same read-side basic-auth credentials
   cli/platform/infra/base/main.tf already collects for Alloy's write side
   (external_loki_username/external_loki_password, OBS-039), mirroring
   --loki-base-url's own flag-wins-over-nothing-else shape but as a
   flag/env pair like Kafka_security.config_of_env()'s KAFKA_SASL_* --
   flag wins over env var, field-by-field. [Error] when exactly one of
   username/password ends up set: Loki basic auth needs both together,
   same as main.tf's precondition on the write side. [Ok None] when
   neither is set -- existing unauthenticated behavior is unchanged. *)
let resolve_credentials ~flag_username ~flag_password ~env_username
    ~env_password : (credentials option, string) result =
  let nonempty = function
    | None -> None
    | Some s ->
        let s = String.trim s in
        if s = "" then None else Some s
  in
  let pick flag env =
    match nonempty flag with Some _ as v -> v | None -> nonempty env
  in
  match (pick flag_username env_username, pick flag_password env_password) with
  | None, None -> Ok None
  | Some username, Some password -> Ok (Some { username; password })
  | Some _, None ->
      Error
        "--loki-username (or SOL_LOKI_USERNAME) is set without a password -- \
         pass --loki-password or set SOL_LOKI_PASSWORD too"
  | None, Some _ ->
      Error
        "--loki-password (or SOL_LOKI_PASSWORD) is set without a username -- \
         pass --loki-username or set SOL_LOKI_USERNAME too"

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

let write_curl_auth_config { username; password } =
  let path = Filename.temp_file "sol-loki-curl-" ".conf" in
  try
    Unix.chmod path 0o600;
    let user = curl_config_quote (username ^ ":" ^ password) in
    Out_channel.with_open_text path (fun oc ->
        output_string oc ("user = \"" ^ user ^ "\"\n"));
    Ok path
  with exn ->
    (try Sys.remove path with _ -> ());
    Error (Printexc.to_string exn)

let query ~base_url ~ns ~k8s_name ?credentials ?(limit = 100) ?(timeout_s = 5.0)
    () : (line list, fetch_error) result =
  let curl_config =
    match credentials with
    | None -> Ok None
    | Some credentials ->
        Result.map Option.some (write_curl_auth_config credentials)
  in
  match curl_config with
  | Error msg -> Error (Other ("could not prepare Loki credentials: " ^ msg))
  | Ok curl_config -> (
      Fun.protect ~finally:(fun () ->
          match curl_config with
          | None -> ()
          | Some path -> ( try Sys.remove path with _ -> ()))
      @@ fun () ->
      let argv =
        query_range_argv ~base_url ~ns ~k8s_name ~limit ~timeout_s ?curl_config
          ()
      in
      let redact =
        match credentials with
        | None -> []
        | Some { password; _ } -> [ password ]
      in
      match
        Sol_cli_process.run
          (Sol_cli_process.cmd ~timeout_s:(timeout_s +. 2.0) ~redact argv)
      with
      | Error e -> Error (classify_process_error e)
      | Ok r when r.Sol_cli_process.exit_code <> 0 ->
          (* OBS-031: route a nonzero curl exit through the same classifier used
       for [Sol_cli_process.run]'s own [Non_zero] error, so connection
       failures/timeouts get "connection failed"/"query timed out" instead
       of a raw curl stderr dump -- [Sol_cli_process.run] (unlike [run_ok])
       never itself produces [Non_zero], so without this the classifier's
       6/7/56/28 handling was unreachable dead code from this call site. *)
          Error
            (classify_process_error
               (Sol_cli_process.Non_zero
                  {
                    exit_code = r.Sol_cli_process.exit_code;
                    stderr = r.Sol_cli_process.stderr;
                  }))
      | Ok r -> (
          let body, code = split_body_and_status r.Sol_cli_process.stdout in
          match code with
          | Some c when c < 200 || c >= 300 -> Error (Http_error c)
          | _ -> (
              match parse_query_range_body body with
              | Ok lines -> Ok lines
              | Error msg -> Error (Other msg))))
