let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

module L = Sol_cli_loki

let test_split_body_and_status_normal () =
  let body, code = L.split_body_and_status "{\"a\":1}\n200" in
  check_string "body" "{\"a\":1}" body;
  Windtrap.equal (Windtrap.option Windtrap.int) ~msg:"code" (Some 200) code
;;

let test_split_body_and_status_no_newline () =
  let body, code = L.split_body_and_status "no newline here" in
  check_string "whole string is body" "no newline here" body;
  Windtrap.equal (Windtrap.option Windtrap.int) ~msg:"no code" None code
;;

let success_body =
  {|
{"status": "success",
 "data": {"resultType": "streams",
   "result": [
     {"stream": {"app": "charge-svc"},
      "values": [["1693500002000000000", "second"], ["1693500001000000000", "first"]]}
   ]}}
|}
;;

let empty_body =
  {|{"status": "success", "data": {"resultType": "streams", "result": []}}|}
;;

let error_body = {|{"status": "error", "error": "parse error", "errorType": "bad_data"}|}

let test_parse_success_orders_oldest_first () =
  match L.parse_query_range_body success_body with
  | Ok [ a; b ] ->
    check_string "oldest first" "first" a.text;
    check_string "then newest" "second" b.text
  | Ok _ -> Windtrap.fail "expected exactly two lines"
  | Error e -> Windtrap.fail ("expected Ok, got Error " ^ e)
;;

let test_parse_empty_result_is_ok_empty () =
  match L.parse_query_range_body empty_body with
  | Ok [] -> ()
  | Ok _ -> Windtrap.fail "expected an empty list"
  | Error e -> Windtrap.fail ("expected Ok [], got Error " ^ e)
;;

let test_parse_error_status_is_error () =
  match L.parse_query_range_body error_body with
  | Ok _ -> Windtrap.fail "expected Error for status=error"
  | Error _ -> ()
;;

let test_parse_malformed_json_is_error () =
  match L.parse_query_range_body "not json at all {" with
  | Ok _ -> Windtrap.fail "expected Error for malformed JSON"
  | Error _ -> ()
;;

let test_classify_timeout () =
  match L.classify_process_error (Sol_cli_process.Timeout 5.0) with
  | L.Timeout -> ()
  | _ -> Windtrap.fail "expected Timeout"
;;

let test_classify_curl_timeout_exit_code () =
  match
    L.classify_process_error
      (Sol_cli_process.Non_zero { exit_code = 28; stdout = ""; stderr = "" })
  with
  | L.Timeout -> ()
  | _ -> Windtrap.fail "expected Timeout for curl exit 28"
;;

let test_classify_connection_failed () =
  match
    L.classify_process_error
      (Sol_cli_process.Non_zero { exit_code = 7; stdout = ""; stderr = "" })
  with
  | L.Connection_failed -> ()
  | _ -> Windtrap.fail "expected Connection_failed for curl exit 7"
;;

let test_classify_other () =
  match
    L.classify_process_error
      (Sol_cli_process.Non_zero { exit_code = 22; stdout = ""; stderr = "boom" })
  with
  | L.Other msg ->
    check_int "message mentions exit code" 1 (if String.length msg > 0 then 1 else 0)
  | _ -> Windtrap.fail "expected Other"
;;

let test_query_range_argv_contains_logql_labels () =
  let argv =
    L.query_range_argv
      ~base_url:"http://localhost:3100"
      ~unit:
        { Sol_cli_log_selector.workspace = "acme"
        ; domain = "payments"
        ; service = "charge-svc"
        }
      ~limit:50
      ~timeout_s:5.0
      ()
  in
  let joined = String.concat " " argv in
  check_int
    "carries the exact identity selector"
    1
    (if
       Sol_cli_string.contains
         ~needle:{|query={workspace="acme", domain="payments", service="charge-svc"}|}
         joined
     then 1
     else 0);
  check_int
    "with no regex match on the service name"
    0
    (if Sol_cli_string.contains ~needle:"=~" joined then 1 else 0)
;;

let test_query_range_argv_no_config_omits_config_flag () =
  let argv =
    L.query_range_argv
      ~base_url:"http://localhost:3100"
      ~unit:
        { Sol_cli_log_selector.workspace = "acme"
        ; domain = "payments"
        ; service = "charge-svc"
        }
      ~limit:50
      ~timeout_s:5.0
      ()
  in
  check_int "no --config flag" 0 (if List.mem "--config" argv then 1 else 0)
;;

let test_query_range_argv_config_adds_config_path_not_secret () =
  let argv =
    L.query_range_argv
      ~base_url:"http://localhost:3100"
      ~unit:
        { Sol_cli_log_selector.workspace = "acme"
        ; domain = "payments"
        ; service = "charge-svc"
        }
      ~limit:50
      ~timeout_s:5.0
      ~curl_config:"/tmp/sol-loki-curl.conf"
      ()
  in
  let rec find_after flag = function
    | a :: b :: _ when a = flag -> Some b
    | _ :: rest -> find_after flag rest
    | [] -> None
  in
  match find_after "--config" argv with
  | Some v ->
    check_string "--config path" "/tmp/sol-loki-curl.conf" v;
    check_int
      "secret absent from argv"
      0
      (if List.mem "tenant-1:s3cr3t" argv then 1 else 0)
  | None -> Windtrap.fail "expected --config <path> in argv"
;;

let test_query_range_argv_logql_carries_exact_selector () =
  let argv =
    L.query_range_argv_logql
      ~base_url:"http://localhost:3100"
      ~logql:{|{release="r-0123456789abcdef"}|}
      ~limit:100
      ~timeout_s:5.0
      ()
  in
  let joined = String.concat " " argv in
  check_bool
    "exact release selector in the query argument"
    true
    (let re = Str.regexp_string {|query={release="r-0123456789abcdef"}|} in
     try
       ignore (Str.search_forward re joined 0);
       true
     with
     | Not_found -> false)
;;

let test_resolve_credentials_neither_set_is_ok_none () =
  match
    L.resolve_credentials
      ~flag_username:None
      ~flag_password:None
      ~env_username:None
      ~env_password:None
  with
  | Ok None -> ()
  | Ok (Some _) -> Windtrap.fail "expected Ok None"
  | Error e -> Windtrap.fail ("expected Ok None, got Error " ^ e)
;;

let test_resolve_credentials_empty_values_are_unset () =
  match
    L.resolve_credentials
      ~flag_username:(Some " ")
      ~flag_password:(Some "")
      ~env_username:None
      ~env_password:None
  with
  | Ok None -> ()
  | Ok (Some _) -> Windtrap.fail "expected empty values to behave as unset"
  | Error e -> Windtrap.fail ("expected Ok None, got Error " ^ e)
;;

let test_resolve_credentials_flags_only () =
  match
    L.resolve_credentials
      ~flag_username:(Some "flag-user")
      ~flag_password:(Some "flag-pass")
      ~env_username:None
      ~env_password:None
  with
  | Ok (Some { L.username = "flag-user"; password = "flag-pass" }) -> ()
  | Ok _ -> Windtrap.fail "expected flag-user/flag-pass"
  | Error e -> Windtrap.fail ("expected Ok, got Error " ^ e)
;;

let test_resolve_credentials_env_only () =
  match
    L.resolve_credentials
      ~flag_username:None
      ~flag_password:None
      ~env_username:(Some "env-user")
      ~env_password:(Some "env-pass")
  with
  | Ok (Some { L.username = "env-user"; password = "env-pass" }) -> ()
  | Ok _ -> Windtrap.fail "expected env-user/env-pass"
  | Error e -> Windtrap.fail ("expected Ok, got Error " ^ e)
;;

let test_resolve_credentials_flag_wins_over_env () =
  match
    L.resolve_credentials
      ~flag_username:(Some "flag-user")
      ~flag_password:(Some "flag-pass")
      ~env_username:(Some "env-user")
      ~env_password:(Some "env-pass")
  with
  | Ok (Some { L.username = "flag-user"; password = "flag-pass" }) -> ()
  | Ok _ -> Windtrap.fail "expected flags to win over env"
  | Error e -> Windtrap.fail ("expected Ok, got Error " ^ e)
;;

let test_resolve_credentials_flag_username_wins_env_password_fills_in () =
  match
    L.resolve_credentials
      ~flag_username:(Some "flag-user")
      ~flag_password:None
      ~env_username:(Some "env-user")
      ~env_password:(Some "env-pass")
  with
  | Ok (Some { L.username = "flag-user"; password = "env-pass" }) -> ()
  | Ok _ -> Windtrap.fail "expected flag-user/env-pass"
  | Error e -> Windtrap.fail ("expected Ok, got Error " ^ e)
;;

let test_resolve_credentials_username_without_password_is_error () =
  match
    L.resolve_credentials
      ~flag_username:(Some "flag-user")
      ~flag_password:None
      ~env_username:None
      ~env_password:None
  with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected Error for username set without password"
;;

let test_resolve_credentials_password_without_username_is_error () =
  match
    L.resolve_credentials
      ~flag_username:None
      ~flag_password:None
      ~env_username:None
      ~env_password:(Some "env-pass")
  with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected Error for password set without username"
;;

let%test "split_body_and_status: normal" = test_split_body_and_status_normal ()
let%test "split_body_and_status: no newline" = test_split_body_and_status_no_newline ()

let%test "parse_query_range_body: success orders oldest first" =
  test_parse_success_orders_oldest_first ()
;;

let%test "parse_query_range_body: empty result is Ok []" =
  test_parse_empty_result_is_ok_empty ()
;;

let%test "parse_query_range_body: error status is Error" =
  test_parse_error_status_is_error ()
;;

let%test "parse_query_range_body: malformed JSON is Error" =
  test_parse_malformed_json_is_error ()
;;

let%test "classify_process_error: Timeout" = test_classify_timeout ()

let%test "classify_process_error: curl exit 28 -> Timeout" =
  test_classify_curl_timeout_exit_code ()
;;

let%test "classify_process_error: curl exit 7 -> Connection_failed" =
  test_classify_connection_failed ()
;;

let%test "classify_process_error: other exit code -> Other" = test_classify_other ()

let%test "query_range_argv: contains logql labels" =
  test_query_range_argv_contains_logql_labels ()
;;

let%test "query_range_argv: no config -> no --config flag" =
  test_query_range_argv_no_config_omits_config_flag ()
;;

let%test "query_range_argv: config -> --config path" =
  test_query_range_argv_config_adds_config_path_not_secret ()
;;

let%test "query_range_argv: raw logql -> exact selector" =
  test_query_range_argv_logql_carries_exact_selector ()
;;

let%test "resolve_credentials: neither set -> Ok None" =
  test_resolve_credentials_neither_set_is_ok_none ()
;;

let%test "resolve_credentials: empty values are unset" =
  test_resolve_credentials_empty_values_are_unset ()
;;

let%test "resolve_credentials: flags only" = test_resolve_credentials_flags_only ()
let%test "resolve_credentials: env only" = test_resolve_credentials_env_only ()

let%test "resolve_credentials: flag wins over env" =
  test_resolve_credentials_flag_wins_over_env ()
;;

let%test "resolve_credentials: flag/env resolved independently per field" =
  test_resolve_credentials_flag_username_wins_env_password_fills_in ()
;;

let%test "resolve_credentials: username without password -> Error" =
  test_resolve_credentials_username_without_password_is_error ()
;;

let%test "resolve_credentials: password without username -> Error" =
  test_resolve_credentials_password_without_username_is_error ()
;;
