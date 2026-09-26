(* REFAC-121 / REFAC-122: Sol_cli_string. *)

module S = Sol_cli_string

let opt = Alcotest.(option string)

let test_blank () =
  Alcotest.(check bool) "empty" true (S.is_blank "");
  Alcotest.(check bool) "whitespace" true (S.is_blank " \t\n");
  Alcotest.(check bool) "text" false (S.is_blank " x ");
  Alcotest.check opt "non_blank trims" (Some "x") (S.non_blank "  x ");
  Alcotest.check opt "non_blank of blank" None (S.non_blank "   ");
  Alcotest.check opt "non_blank_opt None" None (S.non_blank_opt None);
  Alcotest.check opt "non_blank_opt blank" None (S.non_blank_opt (Some " "));
  Alcotest.check opt "non_blank_opt value" (Some "v") (S.non_blank_opt (Some " v"))
;;

(* non_empty treats only "" as absent: whitespace is data there. *)
let test_non_empty () =
  Alcotest.check opt "None" None (S.non_empty None);
  Alcotest.check opt "empty" None (S.non_empty (Some ""));
  Alcotest.check opt "whitespace kept" (Some " ") (S.non_empty (Some " "))
;;

let test_env () =
  Unix.putenv "SOL_TEST_STRING_ENV" "";
  Alcotest.check opt "set to empty is unset" None (S.env "SOL_TEST_STRING_ENV");
  Unix.putenv "SOL_TEST_STRING_ENV" "value";
  Alcotest.check opt "set" (Some "value") (S.env "SOL_TEST_STRING_ENV");
  Alcotest.check opt "unset" None (S.env "SOL_TEST_STRING_ENV_NEVER_SET")
;;

let test_contains () =
  Alcotest.(check bool) "middle" true (S.contains ~needle:"b c" "a b c d");
  Alcotest.(check bool) "start" true (S.contains ~needle:"a" "abc");
  Alcotest.(check bool) "end" true (S.contains ~needle:"bc" "abc");
  Alcotest.(check bool) "absent" false (S.contains ~needle:"x" "abc");
  Alcotest.(check bool) "longer than haystack" false (S.contains ~needle:"abcd" "abc");
  Alcotest.(check bool) "empty needle" true (S.contains ~needle:"" "abc")
;;

let () =
  Alcotest.run
    "string"
    [ ( "string"
      , [ Alcotest.test_case "blank" `Quick test_blank
        ; Alcotest.test_case "non_empty" `Quick test_non_empty
        ; Alcotest.test_case "env" `Quick test_env
        ; Alcotest.test_case "contains" `Quick test_contains
        ] )
    ]
;;
