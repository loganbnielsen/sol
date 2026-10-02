let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual

module D = Sol_cli_deployment_id

let t0 = 1767225600.0
let mk now entropy = D.to_string (D.create ~now ~entropy)

let test_known_vector () =
  check_string "known vector" "d-20260101t000000z-900150983cd24fb0" (mk t0 "abc")
;;

let test_deterministic () =
  check_string "same now + entropy, same id" (mk t0 "seed") (mk t0 "seed")
;;

let test_distinct_entropy_mints_distinct_id () =
  check_bool
    "different entropy, different id"
    true
    (not (String.equal (mk t0 "a") (mk t0 "b")))
;;

let test_later_time_sorts_after () =
  let earlier = mk t0 "same"
  and later = mk (t0 +. 1.0) "same" in
  check_bool "later time sorts after" true (String.compare earlier later < 0)
;;

let test_id_is_lowercase_and_name_safe () =
  let id = mk t0 "x" in
  check_int "length" 35 (String.length id);
  let legal =
    id
    |> String.for_all (fun c ->
      (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-')
  in
  check_bool "only [a-z0-9-] (a legal object-name segment)" true legal;
  check_bool
    "no uppercase (RFC 1123 names are lowercase)"
    false
    (String.exists (fun c -> c >= 'A' && c <= 'Z') id)
;;

let test_random_entropy_has_16_bytes () =
  check_int "16 bytes" 16 (String.length (D.random_entropy ()))
;;

let test_round_trip () =
  let id = mk t0 "abc" in
  match D.of_string id with
  | Ok parsed -> check_string "round trip" id (D.to_string parsed)
  | Error msg -> Windtrap.fail msg
;;

let test_rejects_a_release_id () =
  match D.of_string "r-0123456789abcdef" with
  | Ok _ -> Windtrap.fail "expected a release id to be rejected as a deployment id"
  | Error msg -> check_bool "names the input" true (String.length msg > 0)
;;

let reject label s =
  match D.of_string s with
  | Ok _ -> Windtrap.fail (label ^ ": expected rejection of " ^ s)
  | Error _ -> ()
;;

let test_rejects_malformed () =
  reject "uppercase time" "d-20260101T000000Z-0123456789abcdef";
  reject "wrong prefix" "x-20260101t000000z-0123456789abcdef";
  reject "too short" "d-20260101t000000z-0123456789abcd";
  reject "too long" "d-20260101t000000z-0123456789abcdef0";
  reject "missing dash" "d-20260101t000000z_0123456789abcdef";
  reject "bad time separator" "d-20260101x000000z-0123456789abcdef";
  reject "bad end separator" "d-20260101t000000y-0123456789abcdef";
  reject "non-digit in time" "d-2026010at000000z-0123456789abcdef";
  reject "non-hex entropy" "d-20260101t000000z-0123456789abcdeg";
  reject "uppercase hex" "d-20260101t000000z-0123456789ABCDEF"
;;

let%test "minting: known vector" = test_known_vector ()
let%test "minting: deterministic" = test_deterministic ()

let%test "minting: distinct entropy -> distinct id" =
  test_distinct_entropy_mints_distinct_id ()
;;

let%test "minting: later time sorts after" = test_later_time_sorts_after ()
let%test "minting: lowercase and name-safe" = test_id_is_lowercase_and_name_safe ()
let%test "minting: random entropy is 16 bytes" = test_random_entropy_has_16_bytes ()
let%test "parsing: round trip" = test_round_trip ()
let%test "parsing: rejects a release id" = test_rejects_a_release_id ()
let%test "parsing: rejects malformed" = test_rejects_malformed ()
