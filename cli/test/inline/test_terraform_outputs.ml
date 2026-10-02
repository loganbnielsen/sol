module O = Sol_cli_terraform_outputs

let shown json =
  match O.displayable json with
  | Ok outputs -> List.map O.line outputs
  | Error e -> Windtrap.fail e
;;

let test_selection () =
  let json =
    {|{ "endpoint":   {"sensitive": false, "value": "https://k8s.test"},
        "secret":     {"sensitive": true,  "value": "hunter2"},
        "unmarked":   {"value": "shown only when marked non-sensitive"},
        "subnets":    {"sensitive": false, "value": ["a", 1, "b"]},
        "no_strings": {"sensitive": false, "value": [1, 2]},
        "missing":    {"sensitive": false, "value": null},
        "count":      {"sensitive": false, "value": 3} }|}
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"only non-sensitive strings, string lists and nulls, in order"
    [ Printf.sprintf "  %-28s  %s" "endpoint" "https://k8s.test"
    ; Printf.sprintf "  %-28s  [%s]" "subnets" "a, b"
    ; Printf.sprintf "  %-28s  (none)" "missing"
    ]
    (shown json)
;;

let test_unreadable () =
  (match O.displayable "{not json" with
   | Error _ -> ()
   | Ok _ -> Windtrap.fail "malformed JSON was read");
  match O.displayable "[]" with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "a non-object read as no outputs"
;;

let%test "outputs: selection" = test_selection ()
let%test "outputs: unreadable" = test_unreadable ()
