let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

module U = Sol_cli_observability_url

let url_of = function
  | U.Url s -> s
  | U.No_url reason -> Alcotest.fail ("expected Url, got No_url " ^ reason)
;;

let reason_of = function
  | U.Url s -> Alcotest.fail ("expected No_url, got Url " ^ s)
  | U.No_url reason -> reason
;;

let test_backend_of_string_valid () =
  check_bool "local" true (U.backend_of_string "local" = Some U.Local);
  check_bool
    "self_hosted_durable"
    true
    (U.backend_of_string "self_hosted_durable" = Some U.Self_hosted_durable);
  check_bool "external" true (U.backend_of_string "external" = Some U.External)
;;

let test_backend_of_string_invalid () =
  check_bool "unknown string -> None" true (U.backend_of_string "bogus" = None)
;;

let test_backend_to_string_roundtrip () =
  List.iter
    (fun b ->
       check_bool "roundtrip" true (U.backend_of_string (U.backend_to_string b) = Some b))
    [ U.Local; U.Self_hosted_durable; U.External ]
;;

let test_resolve_local_default () =
  check_string
    "local default"
    "http://localhost:3000"
    (url_of (U.resolve ~backend:U.Local ()))
;;

let test_resolve_self_hosted_durable_with_base_domain () =
  check_string
    "self_hosted_durable"
    "https://grafana.acme.com"
    (url_of (U.resolve ~backend:U.Self_hosted_durable ~base_domain:"acme.com" ()))
;;

let test_resolve_self_hosted_durable_without_base_domain () =
  check_bool
    "no base_domain -> No_url"
    true
    (String.length (reason_of (U.resolve ~backend:U.Self_hosted_durable ())) > 0)
;;

let test_resolve_external_never_guesses () =
  check_bool
    "external -> No_url even with base_domain"
    true
    (String.length (reason_of (U.resolve ~backend:U.External ~base_domain:"acme.com" ()))
     > 0)
;;

let test_resolve_override_wins_for_every_backend () =
  List.iter
    (fun backend ->
       check_string
         "override wins"
         "http://custom:9999"
         (url_of (U.resolve ~backend ~override:"http://custom:9999" ())))
    [ U.Local; U.Self_hosted_durable; U.External ]
;;

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let mkdir_p path =
  let parts = String.split_on_char '/' path in
  let rec loop current = function
    | [] -> ()
    | part :: rest ->
      let next = if current = "" then part else Filename.concat current part in
      (try Unix.mkdir next 0o755 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      loop next rest
  in
  loop "" parts
;;

let with_temp_dir f =
  let dir = Filename.temp_file "sol-obs-url-target-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       write "sol.yml" "";
       f ())
;;

let write_target ~observability_backend_line () =
  mkdir_p "sol/prod/aws";
  Targets_fixture.write
    ~target:"prod/aws/us-east-1"
    (Printf.sprintf
       {|
target:
  base_domain: acme.example.com
  %s
|}
       observability_backend_line)
;;

let ok_pair = function
  | Ok pair -> pair
  | Error msg -> Alcotest.fail ("expected Ok, got Error " ^ msg)
;;

let err_msg = function
  | Ok _ -> Alcotest.fail "expected Error, got Ok"
  | Error msg -> msg
;;

let test_effective_no_target_no_flags_defaults_local () =
  let backend, base_domain =
    ok_pair
      (U.effective_backend_and_base_domain
         ~explicit_backend:None
         ~explicit_base_domain:None
         ~target:None
         ())
  in
  check_bool "defaults to Local" true (backend = U.Local);
  check_bool "no base_domain" true (base_domain = None)
;;

let test_effective_target_supplies_backend_and_base_domain () =
  with_temp_dir (fun () ->
    write_target
      ~observability_backend_line:"observability_backend: self_hosted_durable"
      ();
    let backend, base_domain =
      ok_pair
        (U.effective_backend_and_base_domain
           ~explicit_backend:None
           ~explicit_base_domain:None
           ~target:(Some "prod/aws/us-east-1")
           ())
    in
    check_bool "backend from target" true (backend = U.Self_hosted_durable);
    check_bool "base_domain from target" true (base_domain = Some "acme.example.com"))
;;

let test_effective_target_without_observability_backend_falls_back_to_local () =
  with_temp_dir (fun () ->
    mkdir_p "sol/dev/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      {|
target:
  cluster_name: sol-dev
|};
    let backend, base_domain =
      ok_pair
        (U.effective_backend_and_base_domain
           ~explicit_backend:None
           ~explicit_base_domain:None
           ~target:(Some "dev/aws/us-east-1")
           ())
    in
    check_bool "falls back to Local" true (backend = U.Local);
    check_bool "no base_domain set on this target" true (base_domain = None))
;;

let test_effective_explicit_flag_overrides_target () =
  with_temp_dir (fun () ->
    write_target
      ~observability_backend_line:"observability_backend: self_hosted_durable"
      ();
    let backend, base_domain =
      ok_pair
        (U.effective_backend_and_base_domain
           ~explicit_backend:(Some U.External)
           ~explicit_base_domain:(Some "override.example.com")
           ~target:(Some "prod/aws/us-east-1")
           ())
    in
    check_bool "explicit backend wins" true (backend = U.External);
    check_bool "explicit base_domain wins" true (base_domain = Some "override.example.com"))
;;

let test_effective_invalid_observability_backend_errors () =
  with_temp_dir (fun () ->
    write_target
      ~observability_backend_line:"observability_backend: not-a-real-backend"
      ();
    check_bool
      "invalid value errors"
      true
      (String.length
         (err_msg
            (U.effective_backend_and_base_domain
               ~explicit_backend:None
               ~explicit_base_domain:None
               ~target:(Some "prod/aws/us-east-1")
               ()))
       > 0))
;;

let test_effective_unknown_target_path_errors () =
  with_temp_dir (fun () ->
    check_bool
      "malformed target path errors"
      true
      (String.length
         (err_msg
            (U.effective_backend_and_base_domain
               ~explicit_backend:None
               ~explicit_base_domain:None
               ~target:(Some "not-a-valid-path")
               ()))
       > 0))
;;

let%test "backend_of_string: valid values" = test_backend_of_string_valid ()
let%test "backend_of_string: invalid value" = test_backend_of_string_invalid ()
let%test "backend_of_string: roundtrip" = test_backend_to_string_roundtrip ()
let%test "resolve: local default" = test_resolve_local_default ()

let%test "resolve: self_hosted_durable with base_domain" =
  test_resolve_self_hosted_durable_with_base_domain ()
;;

let%test "resolve: self_hosted_durable without base_domain" =
  test_resolve_self_hosted_durable_without_base_domain ()
;;

let%test "resolve: external never guesses" = test_resolve_external_never_guesses ()

let%test "resolve: override wins for every backend" =
  test_resolve_override_wins_for_every_backend ()
;;

let%test "effective_backend_and_base_domain: no target/flags -> Local default" =
  test_effective_no_target_no_flags_defaults_local ()
;;

let%test "effective_backend_and_base_domain: target supplies backend+base_domain" =
  test_effective_target_supplies_backend_and_base_domain ()
;;

let%test "effective_backend_and_base_domain: target without the field -> Local" =
  test_effective_target_without_observability_backend_falls_back_to_local ()
;;

let%test "effective_backend_and_base_domain: explicit flag overrides target" =
  test_effective_explicit_flag_overrides_target ()
;;

let%test "effective_backend_and_base_domain: invalid observability_backend errors" =
  test_effective_invalid_observability_backend_errors ()
;;

let%test "effective_backend_and_base_domain: unknown/malformed target path errors" =
  test_effective_unknown_target_path_errors ()
;;
