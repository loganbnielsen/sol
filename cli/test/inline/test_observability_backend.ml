let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

module U = Sol_cli_observability_backend

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

let%test "backend_of_string: valid values" = test_backend_of_string_valid ()
let%test "backend_of_string: invalid value" = test_backend_of_string_invalid ()
let%test "backend_of_string: roundtrip" = test_backend_to_string_roundtrip ()
