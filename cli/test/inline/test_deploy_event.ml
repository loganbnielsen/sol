let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let check_strings msg expected actual =
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg expected actual
;;

module E = Sol_cli_deploy_event
module U = Sol_cli_observability_backend

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

(* The deploy event and the rendered workload taxonomy share one identity key
   set; assert the event covers every key the taxonomy owner declares, so a
   rename cannot leave the dashboard join with a stale field name. *)
let test_fields_matches_taxonomy_label_set () =
  let fields = E.fields sample in
  let identity_keys = List.map fst Sol_cli_manifest.observability_identity in
  List.iter
    (fun key ->
       check_bool
         (Printf.sprintf "deploy event carries taxonomy key %S" key)
         true
         (List.mem_assoc key fields))
    identity_keys;
  List.iter
    (fun key ->
       check_bool
         (Printf.sprintf "the release-timeline join key %S is a taxonomy key" key)
         true
         (List.mem key identity_keys))
    [ "workspace"; "domain"; "service" ];
  check_string "workspace value" "acme" (List.assoc "workspace" fields);
  check_string "env value" "prod" (List.assoc "env" fields);
  check_string "domain value" "billing" (List.assoc "domain" fields);
  check_string "service value" "invoicer" (List.assoc "service" fields);
  check_string "primitive value" "svc" (List.assoc "primitive" fields);
  check_string "release value" "r-0123456789abcdef" (List.assoc "release" fields)
;;

let test_fields_are_event_then_identity_then_join_key () =
  let labels = List.map fst (E.fields sample) in
  let identity_keys = List.map fst Sol_cli_manifest.observability_identity in
  check_strings
    "event, the taxonomy keys, then the deployment join key"
    ([ "event" ] @ identity_keys @ [ "deployment_id" ])
    labels
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

let%test "fields: event, taxonomy keys, then deployment_id" =
  test_fields_are_event_then_identity_then_join_key ()
;;

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
