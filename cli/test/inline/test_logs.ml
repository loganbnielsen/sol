let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let test_encode_braces () =
  check_string "braces encoded" "%7Bfoo%7D" (Sol_cli_logs.url_encode_logql "{foo}")
;;

let test_encode_equals () =
  check_string "equals encoded" "a%3Db" (Sol_cli_logs.url_encode_logql "a=b")
;;

let test_encode_double_quote () =
  check_string
    "double-quote encoded"
    "%22hello%22"
    (Sol_cli_logs.url_encode_logql {|"hello"|})
;;

let test_encode_comma () =
  check_string "comma encoded" "a%2Cb" (Sol_cli_logs.url_encode_logql "a,b")
;;

let test_encode_space () =
  check_string
    "space encoded"
    "hello%20world"
    (Sol_cli_logs.url_encode_logql "hello world")
;;

let test_encode_plain_chars () =
  check_string
    "plain alphanum unchanged"
    "abcXYZ0123"
    (Sol_cli_logs.url_encode_logql "abcXYZ0123")
;;

let test_encode_percent () =
  check_string
    "percent encoded (a raw % would look like a malformed escape to a URL parser)"
    "50%25"
    (Sol_cli_logs.url_encode_logql "50%")
;;

let test_encode_plus () =
  check_string "plus encoded" "a%2Bb" (Sol_cli_logs.url_encode_logql "a+b")
;;

let test_encode_ampersand () =
  check_string
    "ampersand encoded (unescaped would start a new query param)"
    "a%26b"
    (Sol_cli_logs.url_encode_logql "a&b")
;;

let test_encode_question_mark () =
  check_string "question mark encoded" "a%3Fb" (Sol_cli_logs.url_encode_logql "a?b")
;;

let test_encode_hash () =
  check_string
    "hash encoded (unescaped would start a URL fragment)"
    "a%23b"
    (Sol_cli_logs.url_encode_logql "a#b")
;;

let make_unit ?(workspace = "acme") ?(domain = "payments") ?(service = "charge-svc") () =
  { Sol_cli_log_selector.workspace; domain; service }
;;

let make_url ?(base_url = "http://localhost:3000") ?(service = "charge-svc") () =
  Sol_cli_logs.grafana_explore_url ~base_url ~unit:(make_unit ~service ())
;;

let test_url_contains_base_url () =
  let url = make_url ~base_url:"http://grafana.example.com:4000" () in
  check_bool
    "base_url prefix present"
    true
    (let prefix = "http://grafana.example.com:4000/explore" in
     String.length url >= String.length prefix
     && String.sub url 0 (String.length prefix) = prefix)
;;

let test_url_contains_service_selector () =
  let url = make_url () in
  check_bool
    "service selector appears in URL"
    true
    (let re = Str.regexp "service" in
     try
       ignore (Str.search_forward re url 0);
       true
     with
     | Not_found -> false)
;;

let test_url_contains_k8s_name () =
  let url = make_url ~service:"invoice-worker" () in
  check_bool
    "k8s_name appears in URL"
    true
    (let re = Str.regexp "invoice-worker" in
     try
       ignore (Str.search_forward re url 0);
       true
     with
     | Not_found -> false)
;;

let test_url_no_raw_braces () =
  let url = make_url () in
  let query_start =
    try Str.search_forward (Str.regexp "?") url 0 with
    | Not_found -> 0
  in
  let query = String.sub url query_start (String.length url - query_start) in
  check_bool "no raw { in query" false (String.contains query '{');
  check_bool "no raw } in query" false (String.contains query '}')
;;

let test_url_no_raw_equals_in_logql () =
  let url = make_url () in
  check_bool
    "%3D present (= encoded in logql)"
    true
    (let re = Str.regexp "%3D" in
     try
       ignore (Str.search_forward re url 0);
       true
     with
     | Not_found -> false)
;;

let test_url_no_raw_double_quotes () =
  let url = make_url () in
  check_bool "no raw double-quote in URL" false (String.contains url '"')
;;

let test_url_default_base () =
  let url =
    Sol_cli_logs.grafana_explore_url
      ~base_url:"http://localhost:3000"
      ~unit:(make_unit ~service:"my-svc" ())
  in
  check_bool
    "starts with default base"
    true
    (let prefix = "http://localhost:3000/" in
     String.length url >= String.length prefix
     && String.sub url 0 (String.length prefix) = prefix)
;;

let test_kubectl_logs_deployment_target () =
  check_string
    "argv"
    "kubectl --context k3d-sol-local logs -n acme-payments deployment/charge-svc \
     --follow --tail=50"
    (String.concat
       " "
       (Sol_cli_logs.kubectl_logs_argv
          ~ctx:Sol_cli_kube_destination.local_context
          ~ns:"acme-payments"
          ~target:(Sol_cli_logs.Deployment "charge-svc")
          ~follow:true
          ~tail:50))
;;

let test_kubectl_logs_fn_target () =
  check_string
    "argv"
    "kubectl --context k3d-sol-local logs -n acme-billing -l app=invoice-fn \
     --all-containers=true --tail=25"
    (String.concat
       " "
       (Sol_cli_logs.kubectl_logs_argv
          ~ctx:Sol_cli_kube_destination.local_context
          ~ns:"acme-billing"
          ~target:(Sol_cli_logs.App_selector "invoice-fn")
          ~follow:false
          ~tail:25))
;;

let test_release_query_malformed_never_consults_store () =
  let consulted = ref false in
  match
    Sol_cli_logs.release_query
      ~release:"banana"
      ~target:"staging"
      ~known:(fun _ ->
        consulted := true;
        true)
      ()
  with
  | Sol_cli_logs.Release_invalid msg ->
    check_bool "store never consulted for a malformed id" false !consulted;
    check_bool
      "message names the bad id"
      true
      (let re = Str.regexp "banana" in
       try
         ignore (Str.search_forward re msg 0);
         true
       with
       | Not_found -> false)
  | _ -> Alcotest.fail "expected Release_invalid"
;;

let test_release_query_unknown_names_target () =
  match
    Sol_cli_logs.release_query
      ~release:"r-0123456789abcdef"
      ~target:"staging"
      ~known:(fun _ -> false)
      ()
  with
  | Sol_cli_logs.Release_unknown { release_id; target } ->
    check_string "id preserved" "r-0123456789abcdef" release_id;
    check_string "target named" "staging" target
  | _ -> Alcotest.fail "expected Release_unknown"
;;

let test_release_query_known_builds_exact_selector () =
  match
    Sol_cli_logs.release_query
      ~release:"r-0123456789abcdef"
      ~target:"staging"
      ~known:(fun _ -> true)
      ()
  with
  | Sol_cli_logs.Release_logs { logql; _ } ->
    check_string
      "selector is the exact release label"
      {|{release="r-0123456789abcdef"}|}
      logql
  | _ -> Alcotest.fail "expected Release_logs"
;;

let test_release_query_scoped_selector_narrows_to_the_unit () =
  match
    Sol_cli_logs.release_query
      ~release:"r-0123456789abcdef"
      ~target:"staging"
      ~known:(fun _ -> true)
      ~unit:
        { Sol_cli_log_selector.workspace = "myapp"
        ; domain = "payments"
        ; service = "charge-svc"
        }
      ()
  with
  | Sol_cli_logs.Release_logs { logql; _ } ->
    check_string
      "selector adds release to the unit's identity selector"
      {|{workspace="myapp", domain="payments", service="charge-svc", release="r-0123456789abcdef"}|}
      logql
  | _ -> Alcotest.fail "expected Release_logs"
;;

let%test "url_encode_logql: braces" = test_encode_braces ()
let%test "url_encode_logql: equals" = test_encode_equals ()
let%test "url_encode_logql: double-quote" = test_encode_double_quote ()
let%test "url_encode_logql: comma" = test_encode_comma ()
let%test "url_encode_logql: space" = test_encode_space ()
let%test "url_encode_logql: plain chars" = test_encode_plain_chars ()
let%test "url_encode_logql: percent" = test_encode_percent ()
let%test "url_encode_logql: plus" = test_encode_plus ()
let%test "url_encode_logql: ampersand" = test_encode_ampersand ()
let%test "url_encode_logql: question mark" = test_encode_question_mark ()
let%test "url_encode_logql: hash" = test_encode_hash ()
let%test "grafana_explore_url: contains base_url" = test_url_contains_base_url ()

let%test "grafana_explore_url: contains service selector" =
  test_url_contains_service_selector ()
;;

let%test "grafana_explore_url: contains k8s_name" = test_url_contains_k8s_name ()
let%test "grafana_explore_url: no raw braces in query" = test_url_no_raw_braces ()
let%test "grafana_explore_url: = encoded as %3D" = test_url_no_raw_equals_in_logql ()
let%test "grafana_explore_url: no raw double-quotes" = test_url_no_raw_double_quotes ()
let%test "grafana_explore_url: default base prefix" = test_url_default_base ()
let%test "kubectl_logs_argv: deployment target" = test_kubectl_logs_deployment_target ()
let%test "kubectl_logs_argv: fn target" = test_kubectl_logs_fn_target ()

let%test "release_query: malformed never consults the store" =
  test_release_query_malformed_never_consults_store ()
;;

let%test "release_query: unknown names the target" =
  test_release_query_unknown_names_target ()
;;

let%test "release_query: known builds the exact selector" =
  test_release_query_known_builds_exact_selector ()
;;

let%test "release_query: scoped selector narrows to the unit" =
  test_release_query_scoped_selector_narrows_to_the_unit ()
;;
