let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let contains = Sol_cli_string.contains

let unit ?(workspace = "acme") ?(domain = "payments") ?(service = "charge-svc") () =
  { Sol_cli_log_selector.workspace; domain; service }
;;

let test_a_unit_is_selected_by_identity_not_by_a_name_substring () =
  check_string
    "the selector is an exact match on all three identity labels"
    {|{workspace="acme", domain="payments", service="charge-svc"}|}
    (Sol_cli_log_selector.unit (unit ()));
  check_bool
    "nothing in the selector is a regex match"
    false
    (contains ~needle:"=~" (Sol_cli_log_selector.unit (unit ())))
;;

let test_a_differently_named_unit_cannot_match_the_same_selector () =
  let selector = Sol_cli_log_selector.unit (unit ()) in
  check_bool
    "a longer name is a different selector, so it cannot be matched by it"
    false
    (String.equal selector (Sol_cli_log_selector.unit (unit ~service:"charge-svc-v2" ())));
  check_bool
    "so is the same name in another workspace"
    false
    (String.equal selector (Sol_cli_log_selector.unit (unit ~workspace:"venus" ())));
  check_bool
    "and the same name in another domain of this workspace"
    false
    (String.equal selector (Sol_cli_log_selector.unit (unit ~domain:"comms" ())))
;;

let test_identity_values_are_sanitized_as_the_pod_labels_were () =
  let sanitized = Sol_cli_kubernetes_name.sanitize_label_value "Charge_Svc" in
  check_bool "the helper really does transform this value" true (sanitized <> "Charge_Svc");
  check_string
    "the selector carries the sanitized value, matching what Sol wrote on the pod"
    (Sol_cli_log_selector.unit (unit ~service:"Charge_Svc" ()))
    (Sol_cli_log_selector.unit (unit ~service:sanitized ()))
;;

let test_release_narrowing_composes_with_the_identity_selector () =
  check_string
    "release narrows the unit selector instead of replacing it"
    {|{workspace="acme", domain="payments", service="charge-svc", release="r-0123456789abcdef"}|}
    (Sol_cli_log_selector.unit_release (unit ()) ~release_id:"r-0123456789abcdef")
;;

let%test "unit selector: identity, not a name substring" =
  test_a_unit_is_selected_by_identity_not_by_a_name_substring ()
;;

let%test "unit selector: another unit cannot match it" =
  test_a_differently_named_unit_cannot_match_the_same_selector ()
;;

let%test "unit selector: values are sanitized as the pod labels were" =
  test_identity_values_are_sanitized_as_the_pod_labels_were ()
;;

let%test "unit selector: --release composes" =
  test_release_narrowing_composes_with_the_identity_selector ()
;;
