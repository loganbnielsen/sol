let check_bool = Alcotest.(check bool)

module S = Sol_cli_status

let test_all_healthy () =
  check_bool
    "no diagnoses -> Healthy"
    true
    (S.rollup_domain_status ~ns_exists:true [] = S.Healthy);
  check_bool
    "all None -> Healthy"
    true
    (S.rollup_domain_status ~ns_exists:true [ None; None ] = S.Healthy)
;;

let test_one_degraded () =
  check_bool
    "one Some -> Degraded"
    true
    (S.rollup_domain_status ~ns_exists:true [ None; Some "charge-svc rollout failed" ]
     = S.Degraded)
;;

let test_not_deployed_overrides_diagnoses () =
  check_bool
    "ns missing -> Not_deployed regardless of diagnoses"
    true
    (S.rollup_domain_status ~ns_exists:false [ None ] = S.Not_deployed);
  check_bool
    "ns missing with a failing diagnosis -> still Not_deployed"
    true
    (S.rollup_domain_status ~ns_exists:false [ Some "x" ] = S.Not_deployed)
;;

let test_domain_status_to_string () =
  check_bool "Healthy label" true (S.domain_status_to_string S.Healthy = "healthy");
  check_bool
    "Degraded label is upper-cased"
    true
    (S.domain_status_to_string S.Degraded = "DEGRADED");
  check_bool
    "Not_deployed label is upper-cased"
    true
    (S.domain_status_to_string S.Not_deployed = "NOT DEPLOYED")
;;

(* ── probe_url / reachability_of_probe (OBS-018) ────────────────────────── *)

module O = Sol_cli_observability_url

let test_probe_url_explicit_always_wins () =
  List.iter
    (fun backend ->
       check_bool
         "explicit url wins"
         true
         (S.probe_url
            ~backend
            ~explicit_url:(Some "http://custom:9999")
            ~default_local_url:"http://localhost:3100"
            ~probe_path:"/ready"
          = Some "http://custom:9999/ready"))
    [ O.Local; O.Self_hosted_durable; O.External ]
;;

let test_probe_url_local_default_when_no_explicit () =
  check_bool
    "local default used"
    true
    (S.probe_url
       ~backend:O.Local
       ~explicit_url:None
       ~default_local_url:"http://localhost:3100"
       ~probe_path:"/ready"
     = Some "http://localhost:3100/ready")
;;

let test_probe_url_non_local_without_explicit_is_none () =
  List.iter
    (fun backend ->
       check_bool
         "no default guessed for non-local"
         true
         (S.probe_url
            ~backend
            ~explicit_url:None
            ~default_local_url:"http://localhost:3100"
            ~probe_path:"/ready"
          = None))
    [ O.Self_hosted_durable; O.External ]
;;

let test_reachability_of_probe_not_checked () =
  check_bool
    "None -> Not_checked"
    true
    (S.reachability_of_probe ~probe_url:None ~is_reachable:(fun _ -> Ok ())
     = S.Not_checked)
;;

let test_reachability_of_probe_healthy () =
  check_bool
    "reachable -> Healthy"
    true
    (S.reachability_of_probe ~probe_url:(Some "http://x") ~is_reachable:(fun _ -> Ok ())
     = S.Healthy)
;;

let test_reachability_of_probe_unreachable () =
  check_bool
    "unreachable -> Unreachable"
    true
    (S.reachability_of_probe ~probe_url:(Some "http://x") ~is_reachable:(fun _ ->
       Error "connection failed")
     = S.Unreachable)
;;

let test_reachability_to_string () =
  check_bool "Healthy label" true (S.reachability_to_string S.Healthy = "healthy");
  check_bool
    "Unreachable label"
    true
    (S.reachability_to_string S.Unreachable = "unreachable");
  check_bool
    "Not_checked label"
    true
    (S.reachability_to_string S.Not_checked = "not checked")
;;

(* ── not_configured_message / unreachable_message (OBS-031) ─────────────── *)

let test_not_configured_message_names_backend_and_flag () =
  let msg = S.not_configured_message ~signal:S.Loki ~backend:O.Self_hosted_durable in
  check_bool
    "mentions the backend"
    true
    (let re = Str.regexp_string "self_hosted_durable" in
     try
       ignore (Str.search_forward re msg 0);
       true
     with
     | Not_found -> false);
  check_bool
    "mentions the flag"
    true
    (let re = Str.regexp_string "--loki-base-url" in
     try
       ignore (Str.search_forward re msg 0);
       true
     with
     | Not_found -> false);
  check_bool
    "mentions the port-forward command"
    true
    (let re = Str.regexp_string "kubectl port-forward -n monitoring svc/loki 3100:3100" in
     try
       ignore (Str.search_forward re msg 0);
       true
     with
     | Not_found -> false)
;;

let test_not_configured_message_prometheus_signal () =
  let msg = S.not_configured_message ~signal:S.Prometheus ~backend:O.External in
  check_bool
    "mentions --prometheus-base-url"
    true
    (let re = Str.regexp_string "--prometheus-base-url" in
     try
       ignore (Str.search_forward re msg 0);
       true
     with
     | Not_found -> false);
  check_bool
    "mentions the prometheus-server port-forward"
    true
    (let re = Str.regexp_string "svc/prometheus-server 9090:80" in
     try
       ignore (Str.search_forward re msg 0);
       true
     with
     | Not_found -> false)
;;

let test_not_configured_message_has_no_trailing_period () =
  let msg = S.not_configured_message ~signal:S.Loki ~backend:O.Self_hosted_durable in
  check_bool
    "caller owns the closing sentence, not the builder"
    true
    (String.length msg > 0 && msg.[String.length msg - 1] <> '.')
;;

let test_not_configured_message_distinct_from_unreachable_message () =
  let not_configured = S.not_configured_message ~signal:S.Loki ~backend:O.External in
  let unreachable = S.unreachable_message ~url:"http://x" ~error:"connection failed" in
  check_bool
    "the two messages are never the same text"
    true
    (not_configured <> unreachable)
;;

let test_unreachable_message_names_url_and_error () =
  let msg =
    S.unreachable_message ~url:"http://loki.example:3100" ~error:"connection failed"
  in
  check_bool
    "mentions the url"
    true
    (let re = Str.regexp_string "http://loki.example:3100" in
     try
       ignore (Str.search_forward re msg 0);
       true
     with
     | Not_found -> false);
  check_bool
    "mentions the error"
    true
    (let re = Str.regexp_string "connection failed" in
     try
       ignore (Str.search_forward re msg 0);
       true
     with
     | Not_found -> false)
;;

(* ── reachability_line (OBS-031) ─────────────────────────────────────────── *)

let test_reachability_line_not_configured () =
  check_bool
    "no probe_url -> not_configured_message"
    true
    (S.reachability_line
       ~signal:S.Loki
       ~backend:O.Self_hosted_durable
       ~probe_url:None
       ~is_reachable:(fun _ -> Ok ())
     = S.not_configured_message ~signal:S.Loki ~backend:O.Self_hosted_durable)
;;

let test_reachability_line_healthy () =
  check_bool
    "reachable -> \"healthy\""
    true
    (S.reachability_line
       ~signal:S.Loki
       ~backend:O.Local
       ~probe_url:(Some "http://x")
       ~is_reachable:(fun _ -> Ok ())
     = "healthy")
;;

let test_reachability_line_unreachable () =
  check_bool
    "unreachable -> unreachable_message"
    true
    (S.reachability_line
       ~signal:S.Prometheus
       ~backend:O.External
       ~probe_url:(Some "http://x")
       ~is_reachable:(fun _ -> Error "connection failed")
     = S.unreachable_message ~url:"http://x" ~error:"connection failed")
;;

(* ── service_is_declared (OBS-022/024) ──────────────────────────────────── *)

let test_service_is_declared_true_for_declared_name () =
  check_bool
    "declared service -> true"
    true
    (S.service_is_declared ~k8s_name:"charge-svc" [ "charge-svc"; "refund-svc" ])
;;

let test_service_is_declared_false_for_undeclared_name () =
  check_bool
    "undeclared service -> false"
    false
    (S.service_is_declared ~k8s_name:"bogus-svc" [ "charge-svc"; "refund-svc" ])
;;

let test_service_is_declared_false_for_empty_domain () =
  check_bool
    "no declared services at all -> false"
    false
    (S.service_is_declared ~k8s_name:"charge-svc" [])
;;

(* ── pod_expectation_of_primitive (OBS-026) ─────────────────────────────── *)

module R = Sol_cli_rollout_diagnosis

let test_pod_expectation_of_primitive () =
  check_bool
    "Fn -> Ephemeral"
    true
    (S.pod_expectation_of_primitive Sol_cli_manifest.Fn = R.Ephemeral);
  check_bool
    "Svc -> Continuous"
    true
    (S.pod_expectation_of_primitive Sol_cli_manifest.Svc = R.Continuous);
  check_bool
    "Worker -> Continuous"
    true
    (S.pod_expectation_of_primitive Sol_cli_manifest.Worker = R.Continuous)
;;

let () =
  Alcotest.run
    "status"
    [ ( "rollup_domain_status"
      , [ Alcotest.test_case "all healthy" `Quick test_all_healthy
        ; Alcotest.test_case "one degraded" `Quick test_one_degraded
        ; Alcotest.test_case
            "not deployed overrides"
            `Quick
            test_not_deployed_overrides_diagnoses
        ] )
    ; ( "domain_status_to_string"
      , [ Alcotest.test_case "labels" `Quick test_domain_status_to_string ] )
    ; ( "probe_url"
      , [ Alcotest.test_case
            "explicit always wins"
            `Quick
            test_probe_url_explicit_always_wins
        ; Alcotest.test_case
            "local default when no explicit"
            `Quick
            test_probe_url_local_default_when_no_explicit
        ; Alcotest.test_case
            "non-local without explicit -> None"
            `Quick
            test_probe_url_non_local_without_explicit_is_none
        ] )
    ; ( "reachability_of_probe"
      , [ Alcotest.test_case
            "None -> Not_checked"
            `Quick
            test_reachability_of_probe_not_checked
        ; Alcotest.test_case
            "reachable -> Healthy"
            `Quick
            test_reachability_of_probe_healthy
        ; Alcotest.test_case
            "unreachable -> Unreachable"
            `Quick
            test_reachability_of_probe_unreachable
        ; Alcotest.test_case
            "reachability_to_string labels"
            `Quick
            test_reachability_to_string
        ] )
    ; ( "not_configured_message / unreachable_message"
      , [ Alcotest.test_case
            "names backend and flag"
            `Quick
            test_not_configured_message_names_backend_and_flag
        ; Alcotest.test_case
            "prometheus signal uses prometheus flag/port-forward"
            `Quick
            test_not_configured_message_prometheus_signal
        ; Alcotest.test_case
            "no trailing period"
            `Quick
            test_not_configured_message_has_no_trailing_period
        ; Alcotest.test_case
            "distinct from unreachable_message"
            `Quick
            test_not_configured_message_distinct_from_unreachable_message
        ; Alcotest.test_case
            "names url and error"
            `Quick
            test_unreachable_message_names_url_and_error
        ] )
    ; ( "reachability_line"
      , [ Alcotest.test_case
            "no probe_url -> not_configured_message"
            `Quick
            test_reachability_line_not_configured
        ; Alcotest.test_case
            "reachable -> \"healthy\""
            `Quick
            test_reachability_line_healthy
        ; Alcotest.test_case
            "unreachable -> unreachable_message"
            `Quick
            test_reachability_line_unreachable
        ] )
    ; ( "service_is_declared"
      , [ Alcotest.test_case
            "declared name -> true"
            `Quick
            test_service_is_declared_true_for_declared_name
        ; Alcotest.test_case
            "undeclared name -> false"
            `Quick
            test_service_is_declared_false_for_undeclared_name
        ; Alcotest.test_case
            "empty domain -> false"
            `Quick
            test_service_is_declared_false_for_empty_domain
        ] )
    ; ( "pod_expectation_of_primitive"
      , [ Alcotest.test_case
            "maps each primitive"
            `Quick
            test_pod_expectation_of_primitive
        ] )
    ]
;;
