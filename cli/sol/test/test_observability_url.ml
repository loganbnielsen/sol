let check_string = Alcotest.(check string)
let check_bool   = Alcotest.(check bool)

module U = Sol_cli_observability_url

let url_of = function
  | U.Url s -> s
  | U.No_url reason -> Alcotest.fail ("expected Url, got No_url " ^ reason)

let reason_of = function
  | U.Url s -> Alcotest.fail ("expected No_url, got Url " ^ s)
  | U.No_url reason -> reason

(* ── backend_of_string / backend_to_string ──────────────────────────────── *)

let test_backend_of_string_valid () =
  check_bool "local"                true (U.backend_of_string "local" = Some U.Local);
  check_bool "self_hosted_durable"   true (U.backend_of_string "self_hosted_durable" = Some U.Self_hosted_durable);
  check_bool "external"              true (U.backend_of_string "external" = Some U.External)

let test_backend_of_string_invalid () =
  check_bool "unknown string -> None" true (U.backend_of_string "bogus" = None)

let test_backend_to_string_roundtrip () =
  List.iter (fun b ->
    check_bool "roundtrip" true
      (U.backend_of_string (U.backend_to_string b) = Some b)
  ) [U.Local; U.Self_hosted_durable; U.External]

(* ── resolve ─────────────────────────────────────────────────────────────── *)

let test_resolve_local_default () =
  check_string "local default" "http://localhost:3000"
    (url_of (U.resolve ~backend:U.Local ()))

let test_resolve_self_hosted_durable_with_base_domain () =
  check_string "self_hosted_durable" "https://grafana.acme.com"
    (url_of (U.resolve ~backend:U.Self_hosted_durable ~base_domain:"acme.com" ()))

let test_resolve_self_hosted_durable_without_base_domain () =
  check_bool "no base_domain -> No_url" true
    (String.length (reason_of (U.resolve ~backend:U.Self_hosted_durable ())) > 0)

let test_resolve_self_hosted_durable_blank_base_domain () =
  check_bool "blank base_domain -> No_url" true
    (String.length (reason_of (U.resolve ~backend:U.Self_hosted_durable ~base_domain:"   " ())) > 0)

let test_resolve_external_never_guesses () =
  check_bool "external -> No_url even with base_domain" true
    (String.length (reason_of (U.resolve ~backend:U.External ~base_domain:"acme.com" ())) > 0)

let test_resolve_override_wins_for_every_backend () =
  List.iter (fun backend ->
    check_string "override wins" "http://custom:9999"
      (url_of (U.resolve ~backend ~override:"http://custom:9999" ()))
  ) [U.Local; U.Self_hosted_durable; U.External]

(* ── effective_backend_and_base_domain ──────────────────────────────────── *)

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let mkdir_p path =
  let parts = String.split_on_char '/' path in
  let rec loop current = function
    | [] -> ()
    | part :: rest ->
      let next = if current = "" then part else Filename.concat current part in
      (try Unix.mkdir next 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      loop next rest
  in
  loop "" parts

let with_temp_dir f =
  let dir = Filename.temp_file "sol-obs-url-target-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () -> Sys.chdir dir; f ())

let write_target ~observability_backend_line () =
  mkdir_p "sol/prod/aws";
  write "sol/prod/aws/us-east-1.yml" (Printf.sprintf {|
target:
  base_domain: acme.example.com
  %s
|} observability_backend_line)

let ok_pair = function
  | Ok pair -> pair
  | Error msg -> Alcotest.fail ("expected Ok, got Error " ^ msg)

let err_msg = function
  | Ok _ -> Alcotest.fail "expected Error, got Ok"
  | Error msg -> msg

let test_effective_no_target_no_flags_defaults_local () =
  let (backend, base_domain) =
    ok_pair (U.effective_backend_and_base_domain
               ~explicit_backend:None ~explicit_base_domain:None ~target:None ())
  in
  check_bool "defaults to Local" true (backend = U.Local);
  check_bool "no base_domain" true (base_domain = None)

let test_effective_target_supplies_backend_and_base_domain () =
  with_temp_dir (fun () ->
    write_target ~observability_backend_line:"observability_backend: self_hosted_durable" ();
    let (backend, base_domain) =
      ok_pair (U.effective_backend_and_base_domain
                 ~explicit_backend:None ~explicit_base_domain:None
                 ~target:(Some "prod/aws/us-east-1") ())
    in
    check_bool "backend from target" true (backend = U.Self_hosted_durable);
    check_bool "base_domain from target" true (base_domain = Some "acme.example.com"))

let test_effective_target_without_observability_backend_falls_back_to_local () =
  with_temp_dir (fun () ->
    mkdir_p "sol/dev/aws";
    write "sol/dev/aws/us-east-1.yml" {|
target:
  cluster_name: sol-dev
|};
    let (backend, base_domain) =
      ok_pair (U.effective_backend_and_base_domain
                 ~explicit_backend:None ~explicit_base_domain:None
                 ~target:(Some "dev/aws/us-east-1") ())
    in
    check_bool "falls back to Local" true (backend = U.Local);
    check_bool "no base_domain set on this target" true (base_domain = None))

let test_effective_explicit_flag_overrides_target () =
  with_temp_dir (fun () ->
    write_target ~observability_backend_line:"observability_backend: self_hosted_durable" ();
    let (backend, base_domain) =
      ok_pair (U.effective_backend_and_base_domain
                 ~explicit_backend:(Some U.External)
                 ~explicit_base_domain:(Some "override.example.com")
                 ~target:(Some "prod/aws/us-east-1") ())
    in
    check_bool "explicit backend wins" true (backend = U.External);
    check_bool "explicit base_domain wins" true (base_domain = Some "override.example.com"))

let test_effective_invalid_observability_backend_errors () =
  with_temp_dir (fun () ->
    write_target ~observability_backend_line:"observability_backend: not-a-real-backend" ();
    check_bool "invalid value errors" true
      (String.length (err_msg (U.effective_backend_and_base_domain
                                  ~explicit_backend:None ~explicit_base_domain:None
                                  ~target:(Some "prod/aws/us-east-1") ())) > 0))

let test_effective_unknown_target_path_errors () =
  with_temp_dir (fun () ->
    check_bool "malformed target path errors" true
      (String.length (err_msg (U.effective_backend_and_base_domain
                                  ~explicit_backend:None ~explicit_base_domain:None
                                  ~target:(Some "not-a-valid-path") ())) > 0))

let () =
  Alcotest.run "observability_url" [
    "backend_of_string", [
      Alcotest.test_case "valid values"   `Quick test_backend_of_string_valid;
      Alcotest.test_case "invalid value"  `Quick test_backend_of_string_invalid;
      Alcotest.test_case "roundtrip"      `Quick test_backend_to_string_roundtrip;
    ];
    "resolve", [
      Alcotest.test_case "local default"                          `Quick test_resolve_local_default;
      Alcotest.test_case "self_hosted_durable with base_domain"    `Quick test_resolve_self_hosted_durable_with_base_domain;
      Alcotest.test_case "self_hosted_durable without base_domain" `Quick test_resolve_self_hosted_durable_without_base_domain;
      Alcotest.test_case "self_hosted_durable blank base_domain"   `Quick test_resolve_self_hosted_durable_blank_base_domain;
      Alcotest.test_case "external never guesses"                  `Quick test_resolve_external_never_guesses;
      Alcotest.test_case "override wins for every backend"         `Quick test_resolve_override_wins_for_every_backend;
    ];
    "effective_backend_and_base_domain", [
      Alcotest.test_case "no target/flags -> Local default"    `Quick test_effective_no_target_no_flags_defaults_local;
      Alcotest.test_case "target supplies backend+base_domain" `Quick test_effective_target_supplies_backend_and_base_domain;
      Alcotest.test_case "target without the field -> Local"   `Quick test_effective_target_without_observability_backend_falls_back_to_local;
      Alcotest.test_case "explicit flag overrides target"      `Quick test_effective_explicit_flag_overrides_target;
      Alcotest.test_case "invalid observability_backend errors" `Quick test_effective_invalid_observability_backend_errors;
      Alcotest.test_case "unknown/malformed target path errors" `Quick test_effective_unknown_target_path_errors;
    ];
  ]
