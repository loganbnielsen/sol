let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

(* ── url_encode_logql ───────────────────────────────────────────────────── *)

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

(* ── grafana_explore_url ────────────────────────────────────────────────── *)

let make_url ?(base_url = "http://localhost:3000") ?(k8s_name = "charge-svc") () =
  Sol_cli_logs.grafana_explore_url ~base_url ~k8s_name
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

(* FRIC-029: the selector matches on "service" (a substring regex), not
   "namespace" -- Sol's Loki streams never carry a "namespace"/"app" label
   pair. *)
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
  let url = make_url ~k8s_name:"invoice-worker" () in
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
  (* Strip the base_url prefix so only the query parameters are inspected. *)
  let query_start =
    try Str.search_forward (Str.regexp "?") url 0 with
    | Not_found -> 0
  in
  let query = String.sub url query_start (String.length url - query_start) in
  check_bool "no raw { in query" false (String.contains query '{');
  check_bool "no raw } in query" false (String.contains query '}')
;;

let test_url_no_raw_equals_in_logql () =
  (* The LogQL expr is embedded in the query value — its = signs must be
     percent-encoded so they don't break URL parsing. *)
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
  (* Raw double-quotes must not appear anywhere in the URL *)
  check_bool "no raw double-quote in URL" false (String.contains url '"')
;;

let test_url_default_base () =
  let url =
    Sol_cli_logs.grafana_explore_url ~base_url:"http://localhost:3000" ~k8s_name:"my-svc"
  in
  check_bool
    "starts with default base"
    true
    (let prefix = "http://localhost:3000/" in
     String.length url >= String.length prefix
     && String.sub url 0 (String.length prefix) = prefix)
;;

(* ── kubectl_logs_argv ─────────────────────────────────────────────────── *)

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

(* ── release_query (FEAT-069) ────────────────────────────────────────────── *)

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
      ~scope:("myapp-payments", "charge-svc")
      ()
  with
  | Sol_cli_logs.Release_logs { logql; _ } ->
    check_string
      "selector adds release to the unit selector"
      {|{service=~".*charge-svc.*",release="r-0123456789abcdef"}|}
      logql
  | _ -> Alcotest.fail "expected Release_logs"
;;

(* ── runner ─────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "logs"
    [ ( "url_encode_logql"
      , [ Alcotest.test_case "braces" `Quick test_encode_braces
        ; Alcotest.test_case "equals" `Quick test_encode_equals
        ; Alcotest.test_case "double-quote" `Quick test_encode_double_quote
        ; Alcotest.test_case "comma" `Quick test_encode_comma
        ; Alcotest.test_case "space" `Quick test_encode_space
        ; Alcotest.test_case "plain chars" `Quick test_encode_plain_chars
        ; Alcotest.test_case "percent" `Quick test_encode_percent
        ; Alcotest.test_case "plus" `Quick test_encode_plus
        ; Alcotest.test_case "ampersand" `Quick test_encode_ampersand
        ; Alcotest.test_case "question mark" `Quick test_encode_question_mark
        ; Alcotest.test_case "hash" `Quick test_encode_hash
        ] )
    ; ( "grafana_explore_url"
      , [ Alcotest.test_case "contains base_url" `Quick test_url_contains_base_url
        ; Alcotest.test_case
            "contains service selector"
            `Quick
            test_url_contains_service_selector
        ; Alcotest.test_case "contains k8s_name" `Quick test_url_contains_k8s_name
        ; Alcotest.test_case "no raw braces in query" `Quick test_url_no_raw_braces
        ; Alcotest.test_case "= encoded as %3D" `Quick test_url_no_raw_equals_in_logql
        ; Alcotest.test_case "no raw double-quotes" `Quick test_url_no_raw_double_quotes
        ; Alcotest.test_case "default base prefix" `Quick test_url_default_base
        ] )
    ; ( "kubectl_logs_argv"
      , [ Alcotest.test_case
            "deployment target"
            `Quick
            test_kubectl_logs_deployment_target
        ; Alcotest.test_case "fn target" `Quick test_kubectl_logs_fn_target
        ] )
    ; ( "release_query"
      , [ Alcotest.test_case
            "malformed never consults the store"
            `Quick
            test_release_query_malformed_never_consults_store
        ; Alcotest.test_case
            "unknown names the target"
            `Quick
            test_release_query_unknown_names_target
        ; Alcotest.test_case
            "known builds the exact selector"
            `Quick
            test_release_query_known_builds_exact_selector
        ; Alcotest.test_case
            "scoped selector narrows to the unit"
            `Quick
            test_release_query_scoped_selector_narrows_to_the_unit
        ] )
    ]
;;
