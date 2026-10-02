let decode = Sol_cli_contract.decode_declared_contract

let test_well_formed () =
  match
    decode
      {|{"events":[{"module":"payments","topic":"payments.charges","partitions":6}]}|}
  with
  | Ok [ { Sol_cli_contract.module_name; topic; partitions } ] ->
    Windtrap.equal Windtrap.string ~msg:"module" "payments" module_name;
    Windtrap.equal Windtrap.string ~msg:"topic" "payments.charges" topic;
    Windtrap.equal Windtrap.int ~msg:"partitions" 6 partitions
  | Ok _ -> Windtrap.fail "expected exactly one declared event"
  | Error reason -> Windtrap.fail ("a well-formed projection failed to decode: " ^ reason)
;;

let test_malformed_json () =
  match decode "not json" with
  | Ok _ -> Windtrap.fail "malformed JSON must not decode"
  | Error reason ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the reason names the problem"
      true
      (Sol_cli_string.contains ~needle:"not JSON" reason)
;;

let test_missing_event_field () =
  match decode {|{"events":[{"module":"payments","topic":"payments.charges"}]}|} with
  | Ok _ -> Windtrap.fail "an event without partitions must be reported"
  | Error _ -> ()
;;

let test_no_events () =
  match decode {|{"other":true}|} with
  | Ok _ -> Windtrap.fail "a projection without events must be reported"
  | Error _ -> ()
;;

let%test "contract: a well-formed projection decodes" = test_well_formed ()
let%test "contract: malformed JSON is reported" = test_malformed_json ()
let%test "contract: a missing event field is reported" = test_missing_event_field ()
let%test "contract: a projection without events is reported" = test_no_events ()
