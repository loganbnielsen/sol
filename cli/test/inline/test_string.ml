module S = Sol_cli_string

let opt = Windtrap.(option string)

let test_blank () =
  Windtrap.equal Windtrap.bool ~msg:"empty" true (S.is_blank "");
  Windtrap.equal Windtrap.bool ~msg:"whitespace" true (S.is_blank " \t\n");
  Windtrap.equal Windtrap.bool ~msg:"text" false (S.is_blank " x ");
  Windtrap.equal opt ~msg:"non_blank trims" (Some "x") (S.non_blank "  x ");
  Windtrap.equal opt ~msg:"non_blank of blank" None (S.non_blank "   ");
  Windtrap.equal opt ~msg:"non_blank_opt None" None (S.non_blank_opt None);
  Windtrap.equal opt ~msg:"non_blank_opt blank" None (S.non_blank_opt (Some " "));
  Windtrap.equal opt ~msg:"non_blank_opt value" (Some "v") (S.non_blank_opt (Some " v"))
;;

let test_non_empty () =
  Windtrap.equal opt ~msg:"None" None (S.non_empty None);
  Windtrap.equal opt ~msg:"empty" None (S.non_empty (Some ""));
  Windtrap.equal opt ~msg:"whitespace kept" (Some " ") (S.non_empty (Some " "))
;;

let test_env () =
  Unix.putenv "SOL_TEST_STRING_ENV" "";
  Windtrap.equal opt ~msg:"set to empty is unset" None (S.env "SOL_TEST_STRING_ENV");
  Unix.putenv "SOL_TEST_STRING_ENV" "value";
  Windtrap.equal opt ~msg:"set" (Some "value") (S.env "SOL_TEST_STRING_ENV");
  Windtrap.equal opt ~msg:"unset" None (S.env "SOL_TEST_STRING_ENV_NEVER_SET")
;;

let test_contains () =
  Windtrap.equal Windtrap.bool ~msg:"middle" true (S.contains ~needle:"b c" "a b c d");
  Windtrap.equal Windtrap.bool ~msg:"start" true (S.contains ~needle:"a" "abc");
  Windtrap.equal Windtrap.bool ~msg:"end" true (S.contains ~needle:"bc" "abc");
  Windtrap.equal Windtrap.bool ~msg:"absent" false (S.contains ~needle:"x" "abc");
  Windtrap.equal
    Windtrap.bool
    ~msg:"longer than haystack"
    false
    (S.contains ~needle:"abcd" "abc");
  Windtrap.equal Windtrap.bool ~msg:"empty needle" true (S.contains ~needle:"" "abc")
;;

let test_cut () =
  Windtrap.equal
    opt
    ~msg:"strip_prefix absent"
    None
    (S.strip_prefix_opt ~prefix:"ab" "cd");
  Windtrap.equal
    opt
    ~msg:"strip_prefix present"
    (Some "cd")
    (S.strip_prefix_opt ~prefix:"ab" "abcd");
  Windtrap.equal
    opt
    ~msg:"strip_prefix whole"
    (Some "")
    (S.strip_prefix_opt ~prefix:"ab" "ab");
  Windtrap.equal
    opt
    ~msg:"strip_prefix empty"
    (Some "ab")
    (S.strip_prefix_opt ~prefix:"" "ab");
  Windtrap.equal opt ~msg:"before absent" None (S.before_opt ~needle:"z" "abc");
  Windtrap.equal opt ~msg:"before present" (Some "a") (S.before_opt ~needle:"bc" "abcd");
  Windtrap.equal opt ~msg:"before at start" (Some "") (S.before_opt ~needle:"a" "abc");
  Windtrap.equal opt ~msg:"after absent" None (S.after_opt ~needle:"z" "abc");
  Windtrap.equal opt ~msg:"after present" (Some "cd") (S.after_opt ~needle:"ab" "abcd");
  Windtrap.equal opt ~msg:"after to end" (Some "") (S.after_opt ~needle:"c" "abc")
;;

let%test "string: blank" = test_blank ()
let%test "string: non_empty" = test_non_empty ()
let%test "string: env" = test_env ()
let%test "string: contains" = test_contains ()
let%test "string: cut helpers" = test_cut ()
