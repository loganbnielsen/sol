let dummy_handler _req = Response.not_found

let test_pattern_segments () =
  match Route.parse_pattern "/users/:id/posts/:post_id" with
  | Error msg -> Windtrap.fail msg
  | Ok p ->
    Windtrap.equal
      Windtrap.string
      ~msg:"source"
      "/users/:id/posts/:post_id"
      (Route.pattern_to_string p);
    Windtrap.equal Windtrap.bool ~msg:"no trailing slash" false p.Route.trailing_slash;
    Windtrap.equal Windtrap.int ~msg:"segment count" 4 (List.length p.Route.segments);
    Windtrap.equal
      Windtrap.bool
      ~msg:"segments"
      true
      (p.Route.segments
       = [ Route.Literal "users"
         ; Route.Param "id"
         ; Route.Literal "posts"
         ; Route.Param "post_id"
         ])
;;

let test_pattern_rejects_missing_leading_slash () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"missing leading slash"
    true
    (Result.is_error (Route.parse_pattern "users/:id"))
;;

let test_pattern_rejects_double_slash () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"double slash"
    true
    (Result.is_error (Route.parse_pattern "/users//:id"))
;;

let test_pattern_rejects_empty_param () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"empty param"
    true
    (Result.is_error (Route.parse_pattern "/users/:"))
;;

let test_constructor_rejects_malformed_pattern () =
  Windtrap.raises
    ~msg:"constructor validates pattern"
    (Invalid_argument "invalid route pattern \"users\": pattern must start with /")
    (fun () -> ignore (Route.get "users" ~auth:`Public dummy_handler))
;;

let test_parse_valid_path () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"valid path → Some"
    true
    (Route.parse_request_path "/users/42" <> None)
;;

let test_parse_double_slash_rejected () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"leading double slash → None"
    true
    (Route.parse_request_path "//users" = None)
;;

let test_parse_interior_double_slash_rejected () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"interior double slash → None"
    true
    (Route.parse_request_path "/users//42" = None)
;;

let test_parse_root () =
  match Route.parse_request_path "/" with
  | None -> Windtrap.fail "root path should be valid"
  | Some (segs, _ts) ->
    Windtrap.equal Windtrap.int ~msg:"root has no segments" 0 (List.length segs)
;;

let test_percent_decode_space () =
  Windtrap.equal Windtrap.string ~msg:"%20 → space" " " (Uri.pct_decode "%20")
;;

let test_percent_decode_slash () =
  Windtrap.equal Windtrap.string ~msg:"%2F → /" "/" (Uri.pct_decode "%2F")
;;

let test_percent_decode_lowercase () =
  Windtrap.equal Windtrap.string ~msg:"%2f lowercase → /" "/" (Uri.pct_decode "%2f")
;;

let test_percent_decode_passthrough () =
  Windtrap.equal
    Windtrap.string
    ~msg:"plain text unchanged"
    "hello"
    (Uri.pct_decode "hello")
;;

let test_percent_decode_malformed () =
  Windtrap.equal
    Windtrap.string
    ~msg:"malformed %GG unchanged"
    "%GG"
    (Uri.pct_decode "%GG")
;;

let test_percent_decode_plus_not_space () =
  Windtrap.equal
    Windtrap.string
    ~msg:"+ not decoded as space"
    "a+b"
    (Uri.pct_decode "a+b")
;;

let () =
  Windtrap.run
    "routing"
    [ Windtrap.group
        "pattern"
        [ Windtrap.test "typed pattern segments" test_pattern_segments
        ; Windtrap.test "missing leading slash" test_pattern_rejects_missing_leading_slash
        ; Windtrap.test "double slash pattern" test_pattern_rejects_double_slash
        ; Windtrap.test "empty param" test_pattern_rejects_empty_param
        ; Windtrap.test "constructor validates" test_constructor_rejects_malformed_pattern
        ]
    ; Windtrap.group
        "parse_request_path"
        [ Windtrap.test "valid path" test_parse_valid_path
        ; Windtrap.test "double slash rejected" test_parse_double_slash_rejected
        ; Windtrap.test "interior // rejected" test_parse_interior_double_slash_rejected
        ; Windtrap.test "root path valid" test_parse_root
        ]
    ; Windtrap.group
        "percent_decode"
        [ Windtrap.test "%20 → space" test_percent_decode_space
        ; Windtrap.test "%2F → /" test_percent_decode_slash
        ; Windtrap.test "%2f lowercase → /" test_percent_decode_lowercase
        ; Windtrap.test "plain text unchanged" test_percent_decode_passthrough
        ; Windtrap.test "malformed %GG unchanged" test_percent_decode_malformed
        ; Windtrap.test "+ not decoded as space" test_percent_decode_plus_not_space
        ]
    ]
;;
