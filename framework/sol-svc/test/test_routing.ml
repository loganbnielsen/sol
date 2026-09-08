let dummy_handler _req = Response.not_found

let test_pattern_segments () =
  match Route.parse_pattern "/users/:id/posts/:post_id" with
  | Error msg -> Alcotest.fail msg
  | Ok p ->
    Alcotest.(check string) "source" "/users/:id/posts/:post_id"
      (Route.pattern_to_string p);
    Alcotest.(check bool) "no trailing slash" false p.Route.trailing_slash;
    Alcotest.(check int) "segment count" 4 (List.length p.Route.segments);
    Alcotest.(check bool) "segments" true
      (p.Route.segments = [
        Route.Literal "users";
        Route.Param "id";
        Route.Literal "posts";
        Route.Param "post_id";
      ])

let test_pattern_rejects_missing_leading_slash () =
  Alcotest.(check bool) "missing leading slash" true
    (Result.is_error (Route.parse_pattern "users/:id"))

let test_pattern_rejects_double_slash () =
  Alcotest.(check bool) "double slash" true
    (Result.is_error (Route.parse_pattern "/users//:id"))

let test_pattern_rejects_empty_param () =
  Alcotest.(check bool) "empty param" true
    (Result.is_error (Route.parse_pattern "/users/:"))

let test_constructor_rejects_malformed_pattern () =
  Alcotest.check_raises "constructor validates pattern"
    (Invalid_argument "invalid route pattern \"users\": pattern must start with /")
    (fun () -> ignore (Route.get "users" ~auth:`Public dummy_handler))

(* ── method_of_http ──────────────────────────────────────────────────── *)

(* ── parse_request_path ─────────────────────────────────────────────────── *)

let test_parse_valid_path () =
  Alcotest.(check bool) "valid path → Some" true
    (Route.parse_request_path "/users/42" <> None)

let test_parse_double_slash_rejected () =
  Alcotest.(check bool) "leading double slash → None" true
    (Route.parse_request_path "//users" = None)

let test_parse_interior_double_slash_rejected () =
  Alcotest.(check bool) "interior double slash → None" true
    (Route.parse_request_path "/users//42" = None)

let test_parse_root () =
  match Route.parse_request_path "/" with
  | None -> Alcotest.fail "root path should be valid"
  | Some (segs, _ts) ->
    Alcotest.(check int) "root has no segments" 0 (List.length segs)

(* ── percent_decode ──────────────────────────────────────────────────────── *)

let test_percent_decode_space () =
  Alcotest.(check string) "%20 → space" " " (Uri.pct_decode "%20")

let test_percent_decode_slash () =
  Alcotest.(check string) "%2F → /" "/" (Uri.pct_decode "%2F")

let test_percent_decode_lowercase () =
  Alcotest.(check string) "%2f lowercase → /" "/" (Uri.pct_decode "%2f")

let test_percent_decode_passthrough () =
  Alcotest.(check string) "plain text unchanged" "hello" (Uri.pct_decode "hello")

let test_percent_decode_malformed () =
  Alcotest.(check string) "malformed %GG unchanged" "%GG" (Uri.pct_decode "%GG")

let test_percent_decode_plus_not_space () =
  Alcotest.(check string) "+ not decoded as space" "a+b" (Uri.pct_decode "a+b")

let () =
  Alcotest.run "routing" [
    "pattern", [
      Alcotest.test_case "typed pattern segments"  `Quick test_pattern_segments;
      Alcotest.test_case "missing leading slash"   `Quick test_pattern_rejects_missing_leading_slash;
      Alcotest.test_case "double slash pattern"    `Quick test_pattern_rejects_double_slash;
      Alcotest.test_case "empty param"             `Quick test_pattern_rejects_empty_param;
      Alcotest.test_case "constructor validates"   `Quick test_constructor_rejects_malformed_pattern;
    ];
    "parse_request_path", [
      Alcotest.test_case "valid path"              `Quick test_parse_valid_path;
      Alcotest.test_case "double slash rejected"   `Quick test_parse_double_slash_rejected;
      Alcotest.test_case "interior // rejected"    `Quick test_parse_interior_double_slash_rejected;
      Alcotest.test_case "root path valid"         `Quick test_parse_root;
    ];
    "percent_decode", [
      Alcotest.test_case "%20 → space"             `Quick test_percent_decode_space;
      Alcotest.test_case "%2F → /"                 `Quick test_percent_decode_slash;
      Alcotest.test_case "%2f lowercase → /"       `Quick test_percent_decode_lowercase;
      Alcotest.test_case "plain text unchanged"    `Quick test_percent_decode_passthrough;
      Alcotest.test_case "malformed %GG unchanged" `Quick test_percent_decode_malformed;
      Alcotest.test_case "+ not decoded as space"  `Quick test_percent_decode_plus_not_space;
    ];
  ]
