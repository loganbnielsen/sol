let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

module E = Sol_cli_deploy_event
module U = Sol_cli_observability_url

let sample =
  { E.workspace = "acme"
  ; env = "prod"
  ; domain = "billing"
  ; service = "invoicer"
  ; primitive = "svc"
  ; release_id = Result.get_ok (Sol_cli_release_id.of_string "r-0123456789abcdef")
  ; deployment_id =
      Result.get_ok
        (Sol_cli_deployment_id.of_string "d-20260101t000000z-0123456789abcdef")
  }
;;

let test_fields_includes_event_deploy () =
  let fields = E.fields sample in
  check_bool "event=deploy present" true (List.mem ("event", "deploy") fields)
;;

let test_fields_includes_deployment_id_join_key () =
  let fields = E.fields sample in
  check_bool
    "deployment_id present (FEAT-070 join key)"
    true
    (List.mem ("deployment_id", "d-20260101t000000z-0123456789abcdef") fields)
;;

let test_fields_matches_taxonomy_label_set () =
  let fields = E.fields sample in
  check_bool "workspace" true (List.mem ("workspace", "acme") fields);
  check_bool "env" true (List.mem ("env", "prod") fields);
  check_bool "domain" true (List.mem ("domain", "billing") fields);
  check_bool "service" true (List.mem ("service", "invoicer") fields);
  check_bool "primitive" true (List.mem ("primitive", "svc") fields);
  check_bool "release" true (List.mem ("release", "r-0123456789abcdef") fields)
;;

let test_message_mentions_domain_service_and_release () =
  let msg = E.message sample in
  check_bool "mentions domain" true (Sol_cli_string.contains ~needle:"billing" msg);
  check_bool "mentions service" true (Sol_cli_string.contains ~needle:"invoicer" msg);
  check_bool
    "mentions release"
    true
    (Sol_cli_string.contains ~needle:"r-0123456789abcdef" msg)
;;

let explicit_url_case backend () =
  match E.resolve_push_url ~backend ~explicit_url:(Some "http://custom:9999") with
  | E.Explicit url -> check_string "explicit url" "http://custom:9999" url
  | E.Auto_detect -> Windtrap.fail "expected Explicit, got Auto_detect"
  | E.Skip reason -> Windtrap.fail ("expected Explicit, got Skip " ^ reason)
;;

let test_local_without_override_auto_detects () =
  match E.resolve_push_url ~backend:U.Local ~explicit_url:None with
  | E.Auto_detect -> ()
  | E.Explicit url -> Windtrap.fail ("expected Auto_detect, got Explicit " ^ url)
  | E.Skip reason -> Windtrap.fail ("expected Auto_detect, got Skip " ^ reason)
;;

let test_self_hosted_durable_without_override_auto_detects () =
  match E.resolve_push_url ~backend:U.Self_hosted_durable ~explicit_url:None with
  | E.Auto_detect -> ()
  | E.Explicit url -> Windtrap.fail ("expected Auto_detect, got Explicit " ^ url)
  | E.Skip reason -> Windtrap.fail ("expected Auto_detect, got Skip " ^ reason)
;;

let test_external_without_override_skips () =
  match E.resolve_push_url ~backend:U.External ~explicit_url:None with
  | E.Skip reason -> check_bool "non-empty reason" true (String.length reason > 0)
  | E.Explicit url -> Windtrap.fail ("expected Skip, got Explicit " ^ url)
  | E.Auto_detect -> Windtrap.fail "expected Skip, got Auto_detect"
;;

let%test "fields: includes event=deploy" = test_fields_includes_event_deploy ()
let%test "fields: matches taxonomy label set" = test_fields_matches_taxonomy_label_set ()

let%test "fields: includes deployment_id join key" =
  test_fields_includes_deployment_id_join_key ()
;;

let%test "message: mentions domain/service/release" =
  test_message_mentions_domain_service_and_release ()
;;

let%test "resolve_push_url: local explicit url wins" = explicit_url_case U.Local ()

let%test "resolve_push_url: self_hosted_durable explicit url wins" =
  explicit_url_case U.Self_hosted_durable ()
;;

let%test "resolve_push_url: external explicit url wins" = explicit_url_case U.External ()

let%test "resolve_push_url: local -> Auto_detect" =
  test_local_without_override_auto_detects ()
;;

let%test "resolve_push_url: self_hosted_durable -> Auto_detect" =
  test_self_hosted_durable_without_override_auto_detects ()
;;

let%test "resolve_push_url: external -> Skip" = test_external_without_override_skips ()
