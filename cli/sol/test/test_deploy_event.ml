let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

module E = Sol_cli_deploy_event
module U = Sol_cli_observability_url

let sample =
  {
    E.workspace = "acme";
    env = "prod";
    domain = "billing";
    service = "invoicer";
    primitive = "svc";
    release = "a1b2c3d";
  }

(* ── fields ──────────────────────────────────────────────────────────────── *)

let test_fields_includes_event_deploy () =
  let fields = E.fields sample in
  check_bool "event=deploy present" true (List.mem ("event", "deploy") fields)

let test_fields_matches_taxonomy_label_set () =
  let fields = E.fields sample in
  check_bool "workspace" true (List.mem ("workspace", "acme") fields);
  check_bool "env" true (List.mem ("env", "prod") fields);
  check_bool "domain" true (List.mem ("domain", "billing") fields);
  check_bool "service" true (List.mem ("service", "invoicer") fields);
  check_bool "primitive" true (List.mem ("primitive", "svc") fields);
  check_bool "release" true (List.mem ("release", "a1b2c3d") fields)

(* ── message ─────────────────────────────────────────────────────────────── *)

let test_message_mentions_domain_service_and_release () =
  let msg = E.message sample in
  let contains substring s =
    let sl = String.length s and bl = String.length substring in
    let rec go i =
      i + bl <= sl && (String.sub s i bl = substring || go (i + 1))
    in
    go 0
  in
  check_bool "mentions domain" true (contains "billing" msg);
  check_bool "mentions service" true (contains "invoicer" msg);
  check_bool "mentions release" true (contains "a1b2c3d" msg)

(* ── resolve_push_url ────────────────────────────────────────────────────── *)

let test_explicit_url_always_wins =
  [ U.Local; U.Self_hosted_durable; U.External ]
  |> List.map (fun backend ->
      Alcotest.test_case (U.backend_to_string backend) `Quick (fun () ->
          match
            E.resolve_push_url ~backend
              ~explicit_url:(Some "http://custom:9999")
          with
          | E.Explicit url ->
              check_string "explicit url" "http://custom:9999" url
          | E.Auto_detect -> Alcotest.fail "expected Explicit, got Auto_detect"
          | E.Skip reason ->
              Alcotest.fail ("expected Explicit, got Skip " ^ reason)))

let test_local_without_override_auto_detects () =
  match E.resolve_push_url ~backend:U.Local ~explicit_url:None with
  | E.Auto_detect -> ()
  | E.Explicit url -> Alcotest.fail ("expected Auto_detect, got Explicit " ^ url)
  | E.Skip reason -> Alcotest.fail ("expected Auto_detect, got Skip " ^ reason)

let test_self_hosted_durable_without_override_auto_detects () =
  match
    E.resolve_push_url ~backend:U.Self_hosted_durable ~explicit_url:None
  with
  | E.Auto_detect -> ()
  | E.Explicit url -> Alcotest.fail ("expected Auto_detect, got Explicit " ^ url)
  | E.Skip reason -> Alcotest.fail ("expected Auto_detect, got Skip " ^ reason)

let test_external_without_override_skips () =
  match E.resolve_push_url ~backend:U.External ~explicit_url:None with
  | E.Skip reason ->
      check_bool "non-empty reason" true (String.length reason > 0)
  | E.Explicit url -> Alcotest.fail ("expected Skip, got Explicit " ^ url)
  | E.Auto_detect -> Alcotest.fail "expected Skip, got Auto_detect"

let () =
  Alcotest.run "deploy_event"
    [
      ( "fields",
        [
          Alcotest.test_case "includes event=deploy" `Quick
            test_fields_includes_event_deploy;
          Alcotest.test_case "matches taxonomy label set" `Quick
            test_fields_matches_taxonomy_label_set;
        ] );
      ( "message",
        [
          Alcotest.test_case "mentions domain/service/release" `Quick
            test_message_mentions_domain_service_and_release;
        ] );
      ( "resolve_push_url",
        test_explicit_url_always_wins
        @ [
            Alcotest.test_case "local -> Auto_detect" `Quick
              test_local_without_override_auto_detects;
            Alcotest.test_case "self_hosted_durable -> Auto_detect" `Quick
              test_self_hosted_durable_without_override_auto_detects;
            Alcotest.test_case "external -> Skip" `Quick
              test_external_without_override_skips;
          ] );
    ]
