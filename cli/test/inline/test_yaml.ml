let render_value v = Sol_cli_yaml.render [ Sol_cli_yaml.document v ]

let read_back text =
  let prefix = "---\n" in
  let n = String.length prefix in
  Alcotest.(check string) "a document starts with ---" prefix (String.sub text 0 n);
  match Yaml.of_string (String.sub text n (String.length text - n)) with
  | Ok v -> v
  | Error (`Msg m) -> Alcotest.failf "rendered YAML does not parse: %s\n%s" m text
;;

let hostile =
  [ {|he said "hi"|}
  ; "a\\b"
  ; "line one\nline two"
  ; "key: value"
  ; "- not a list"
  ; "# not a comment"
  ; "  leading and trailing  "
  ; "{ not: a map }"
  ; "trailing colon:"
  ; "tab\there"
  ; "*alias"
  ; "&anchor"
  ; "!tag"
  ; "%directive"
  ; "@at"
  ; "`backtick"
  ; "|"
  ; ">"
  ; ""
  ; String.make 120 'x' ^ " with a long tail " ^ String.make 120 'y'
  ; "\"\n  INJECTED: \"yes"
  ; "CREATE TABLE t (id int);\r\nINSERT INTO t VALUES (1);\r\n"
  ; "bell\007 and escape\027 inside"
  ]
;;

let typed_lookalikes =
  [ "true"
  ; "False"
  ; "yes"
  ; "NO"
  ; "on"
  ; "Off"
  ; "y"
  ; "n"
  ; "null"
  ; "~"
  ; "012"
  ; "1.10"
  ; "0x1F"
  ; "1e3"
  ; "-1"
  ; "+2"
  ; ".5"
  ; ".inf"
  ; "-.inf"
  ; ".NaN"
  ; "1_000"
  ; "12:30"
  ]
;;

let round_trips_exactly make label =
  hostile @ typed_lookalikes
  |> List.iter (fun s ->
    let text = render_value (Sol_cli_yaml.map [ "v", make s ]) in
    match read_back text with
    | `O [ ("v", `String got) ] -> Alcotest.(check string) (label ^ ": " ^ s) s got
    | other ->
      Alcotest.failf
        "%s: %S came back as %s (rendered:\n%s)"
        label
        s
        (Yaml.to_string_exn other)
        text)
;;

let test_string_round_trips () = round_trips_exactly Sol_cli_yaml.string "string"
let test_quoted_round_trips () = round_trips_exactly Sol_cli_yaml.quoted "quoted"

let test_plain_where_safe () =
  [ "charge-svc"
  ; "sol-registry:5000/myapp/charge-svc:abc123"
  ; "100m"
  ; "128Mi"
  ; "/healthz"
  ; "kubernetes.io/hostname"
  ; "myapp-payments"
  ; "app@sha256:abc"
  ]
  |> List.iter (fun s ->
    Alcotest.(check bool) ("plain: " ^ s) true (Sol_cli_yaml.plain_safe s));
  hostile @ typed_lookalikes
  |> List.iter (fun s ->
    Alcotest.(check bool) ("quoted: " ^ s) false (Sol_cli_yaml.plain_safe s))
;;

let test_scalars_keep_their_types () =
  let text =
    render_value
      (Sol_cli_yaml.map
         [ "i", Sol_cli_yaml.int 8080
         ; "b", Sol_cli_yaml.bool false
         ; "s", Sol_cli_yaml.string "x"
         ])
  in
  match read_back text with
  | `O [ ("i", `Float 8080.); ("b", `Bool false); ("s", `String "x") ] -> ()
  | _ -> Alcotest.failf "unexpected types in:\n%s" text
;;

let test_literal_round_trips () =
  [ "{\n  \"a\": 1\n}\n"
  ; "no trailing newline\nsecond"
  ; "two trailing\n\n"
  ; "  indented first line\nthen not"
  ; "key: value\n# comment-looking\n- list-looking\n"
  ]
  |> List.iter (fun s ->
    let text = render_value (Sol_cli_yaml.map [ "v", Sol_cli_yaml.literal s ]) in
    match read_back text with
    | `O [ ("v", `String got) ] -> Alcotest.(check string) ("literal: " ^ s) s got
    | _ -> Alcotest.failf "literal %S did not come back as a string:\n%s" s text)
;;

let test_nul_is_refused_not_truncated () =
  Alcotest.check_raises
    "a NUL cannot silently end a value"
    (Invalid_argument "Sol_cli_yaml: a NUL character cannot be written to YAML")
    (fun () -> ignore (Sol_cli_yaml.quoted "before\000after"))
;;

let test_empty_collections () =
  let text =
    render_value
      (Sol_cli_yaml.map [ "m", Sol_cli_yaml.map []; "l", Sol_cli_yaml.list [] ])
  in
  Alcotest.(check string) "flow-style empties" "---\nm: {}\nl: []\n" text
;;

let test_documents_and_comments () =
  let doc = Sol_cli_yaml.map [ "kind", Sol_cli_yaml.string "Secret" ] in
  Alcotest.(check string)
    "each document opens with ---, comments follow it"
    "---\n# fill me in\nkind: Secret\n---\nkind: Secret\n"
    (Sol_cli_yaml.render
       [ Sol_cli_yaml.document ~comments:[ "fill me in" ] doc; Sol_cli_yaml.document doc ]);
  Alcotest.(check string) "no documents, no text" "" (Sol_cli_yaml.render [])
;;

let%test "REFAC-131: string round-trips exactly" = test_string_round_trips ()
let%test "REFAC-131: quoted round-trips exactly" = test_quoted_round_trips ()
let%test "REFAC-131: plain only where safe" = test_plain_where_safe ()
let%test "REFAC-131: ints and bools stay typed" = test_scalars_keep_their_types ()
let%test "REFAC-131: literal blocks round-trip exactly" = test_literal_round_trips ()
let%test "REFAC-131: NUL is refused, not truncated" = test_nul_is_refused_not_truncated ()
let%test "REFAC-131: empty collections" = test_empty_collections ()
let%test "REFAC-131: documents and comments" = test_documents_and_comments ()
