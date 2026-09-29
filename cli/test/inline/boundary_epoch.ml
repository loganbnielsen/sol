let%test "contains finds a substring" =
  Windtrap.equal Windtrap.bool true (Sol_cli_string.contains ~needle:"b" "abc")
;;

let%test "contains rejects an absent substring" =
  Windtrap.equal Windtrap.bool false (Sol_cli_string.contains ~needle:"z" "abc")
;;

let%test "is_blank accepts whitespace only" =
  Windtrap.equal Windtrap.bool true (Sol_cli_string.is_blank "  ")
;;
