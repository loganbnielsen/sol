let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

module S = Sol_cli_status
module D = Sol_cli_rollout_diagnosis

let test_all_healthy () =
  check_bool
    "a read namespace with no services -> Healthy"
    true
    (S.rollup_domain_status ~ns_presence:Ns_present [] = S.Healthy);
  check_bool
    "all diagnosed healthy -> Healthy"
    true
    (S.rollup_domain_status ~ns_presence:Ns_present [ D.Healthy; D.Healthy ] = S.Healthy)
;;

let test_one_degraded () =
  check_bool
    "one diagnosed unhealthy -> Degraded"
    true
    (S.rollup_domain_status
       ~ns_presence:Ns_present
       [ D.Healthy; D.Unhealthy "charge-svc rollout failed" ]
     = S.Degraded)
;;

let test_unreadable_is_unknown_not_healthy () =
  let status =
    S.rollup_domain_status
      ~ns_presence:Ns_present
      [ D.Undetermined "pods could not be read: Error from server (Forbidden)" ]
  in
  check_bool "an unreadable workload is not Healthy" false (status = S.Healthy);
  (match status with
   | S.Unknown why ->
     check_bool
       "the verdict carries why"
       true
       (Sol_cli_string.contains ~needle:"Forbidden" why)
   | other -> Windtrap.fail ("expected Unknown, got " ^ S.domain_status_to_string other));
  check_bool
    "a successful read with nothing wrong is still Healthy"
    true
    (S.rollup_domain_status ~ns_presence:Ns_present [ D.Healthy ] = S.Healthy)
;;

let test_unreadable_namespace_is_unknown_not_absent () =
  (match S.rollup_domain_status ~ns_presence:(Ns_unreadable "forbidden") [] with
   | S.Unknown _ -> ()
   | other ->
     Windtrap.fail
       ("an unreadable namespace must be Unknown, got " ^ S.domain_status_to_string other));
  check_bool
    "a confirmed absent namespace is still Not_deployed"
    true
    (S.rollup_domain_status ~ns_presence:Ns_absent [] = S.Not_deployed)
;;

let test_a_known_fault_outranks_an_unknown () =
  check_bool
    "unhealthy beats undetermined"
    true
    (S.rollup_domain_status
       ~ns_presence:Ns_present
       [ D.Undetermined "x could not be read"; D.Unhealthy "y rollout failed" ]
     = S.Degraded)
;;

let test_not_deployed_overrides_diagnoses () =
  check_bool
    "ns absent -> Not_deployed regardless of diagnoses"
    true
    (S.rollup_domain_status ~ns_presence:Ns_absent [ D.Healthy ] = S.Not_deployed);
  check_bool
    "ns absent with a failing diagnosis -> still Not_deployed"
    true
    (S.rollup_domain_status ~ns_presence:Ns_absent [ D.Unhealthy "x" ] = S.Not_deployed)
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
    (S.domain_status_to_string S.Not_deployed = "NOT DEPLOYED");
  check_bool
    "Unknown carries its reason"
    true
    (S.domain_status_to_string (S.Unknown "pods could not be read: Forbidden")
     = "UNKNOWN (pods could not be read: Forbidden)");
  check_bool
    "Unknown renders one line"
    true
    (S.domain_status_to_string (S.Unknown "first line\nsecond line")
     = "UNKNOWN (first line)")
;;

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
     = S.Unreachable "connection failed")
;;

let test_reachability_to_string () =
  check_bool "Healthy label" true (S.reachability_to_string S.Healthy = "healthy");
  check_bool
    "Unreachable label"
    true
    (S.reachability_to_string (S.Unreachable "HTTP 503") = "unreachable (HTTP 503)");
  check_bool
    "Not_checked label"
    true
    (S.reachability_to_string S.Not_checked = "not checked")
;;

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

let%test "rollup_domain_status: all healthy" = test_all_healthy ()
let%test "rollup_domain_status: one degraded" = test_one_degraded ()

let%test "rollup_domain_status: an unreadable workload is Unknown, never Healthy" =
  test_unreadable_is_unknown_not_healthy ()
;;

let%test "rollup_domain_status: an unreadable namespace is Unknown, not Not_deployed" =
  test_unreadable_namespace_is_unknown_not_absent ()
;;

let%test "rollup_domain_status: a known fault outranks an unknown" =
  test_a_known_fault_outranks_an_unknown ()
;;

let%test "rollup_domain_status: not deployed overrides" =
  test_not_deployed_overrides_diagnoses ()
;;

let%test "domain_status_to_string: labels" = test_domain_status_to_string ()
let%test "probe_url: explicit always wins" = test_probe_url_explicit_always_wins ()

let%test "probe_url: local default when no explicit" =
  test_probe_url_local_default_when_no_explicit ()
;;

let%test "probe_url: non-local without explicit -> None" =
  test_probe_url_non_local_without_explicit_is_none ()
;;

let%test "reachability_of_probe: None -> Not_checked" =
  test_reachability_of_probe_not_checked ()
;;

let%test "reachability_of_probe: reachable -> Healthy" =
  test_reachability_of_probe_healthy ()
;;

let%test "reachability_of_probe: unreachable -> Unreachable" =
  test_reachability_of_probe_unreachable ()
;;

let%test "reachability_of_probe: reachability_to_string labels" =
  test_reachability_to_string ()
;;

let%test "not_configured_message / unreachable_message: names backend and flag" =
  test_not_configured_message_names_backend_and_flag ()
;;

let%test
    "not_configured_message / unreachable_message: prometheus signal uses prometheus \
     flag/port-forward"
  =
  test_not_configured_message_prometheus_signal ()
;;

let%test "not_configured_message / unreachable_message: no trailing period" =
  test_not_configured_message_has_no_trailing_period ()
;;

let%test "not_configured_message / unreachable_message: distinct from unreachable_message"
  =
  test_not_configured_message_distinct_from_unreachable_message ()
;;

let%test "not_configured_message / unreachable_message: names url and error" =
  test_unreachable_message_names_url_and_error ()
;;

let%test "reachability_line: no probe_url -> not_configured_message" =
  test_reachability_line_not_configured ()
;;

let%test "reachability_line: reachable -> \"healthy\"" = test_reachability_line_healthy ()

let%test "reachability_line: unreachable -> unreachable_message" =
  test_reachability_line_unreachable ()
;;

let%test "service_is_declared: declared name -> true" =
  test_service_is_declared_true_for_declared_name ()
;;

let%test "service_is_declared: undeclared name -> false" =
  test_service_is_declared_false_for_undeclared_name ()
;;

let%test "service_is_declared: empty domain -> false" =
  test_service_is_declared_false_for_empty_domain ()
;;

let%test "pod_expectation_of_primitive: maps each primitive" =
  test_pod_expectation_of_primitive ()
;;
