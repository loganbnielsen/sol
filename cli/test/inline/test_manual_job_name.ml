let is_lower_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
let all_lower_hex s = String.length s > 0 && String.for_all is_lower_hex s

let is_valid_k8s_name s =
  match Sol_cli_kubernetes_name.validate_dns_label s with
  | Ok () -> true
  | Error _ -> false
;;

let base_of name =
  let marker = "-manual-" in
  let mlen = String.length marker in
  let rec scan i =
    if i + mlen > String.length name
    then name
    else if String.equal (String.sub name i mlen) marker
    then String.sub name 0 i
    else scan (i + 1)
  in
  scan 0
;;

let test_shape_is_stable_for_given_inputs () =
  let name =
    Sol_cli_manual_job_name.of_parts
      ~k8s_name:"order-svc"
      ~now:1790050573.
      ~entropy:"seed"
  in
  let expected_prefix = "order-svc-manual-1790050573-" in
  Windtrap.equal
    Windtrap.bool
    ~msg:"prefix is <k8s_name>-manual-<seconds>-"
    true
    (String.starts_with ~prefix:expected_prefix name);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the tail is hex entropy"
    true
    (all_lower_hex (String.sub name (String.length expected_prefix) 8));
  Windtrap.equal
    Windtrap.string
    ~msg:"the same inputs give the same name"
    name
    (Sol_cli_manual_job_name.of_parts
       ~k8s_name:"order-svc"
       ~now:1790050573.
       ~entropy:"seed")
;;

let test_same_second_different_runs_do_not_collide () =
  let at = 1790050573. in
  let first =
    Sol_cli_manual_job_name.of_parts ~k8s_name:"order-svc" ~now:at ~entropy:"run-one"
  in
  let second =
    Sol_cli_manual_job_name.of_parts ~k8s_name:"order-svc" ~now:at ~entropy:"run-two"
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"two runs in the same second produce different names"
    true
    (not (String.equal first second))
;;

let test_mint_in_immediate_succession_differs () =
  let first = Sol_cli_manual_job_name.mint ~k8s_name:"order-svc" in
  let second = Sol_cli_manual_job_name.mint ~k8s_name:"order-svc" in
  Windtrap.equal
    Windtrap.bool
    ~msg:"two successive mint calls differ"
    true
    (not (String.equal first second));
  Windtrap.equal
    Windtrap.bool
    ~msg:"and both are legal names"
    true
    (is_valid_k8s_name first);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and both are legal names"
    true
    (is_valid_k8s_name second)
;;

let test_long_base_is_shortened_not_the_entropy () =
  let k8s_name = String.make 63 'a' in
  let first =
    Sol_cli_manual_job_name.of_parts ~k8s_name ~now:1790050573. ~entropy:"run-one"
  in
  let second =
    Sol_cli_manual_job_name.of_parts ~k8s_name ~now:1790050573. ~entropy:"run-two"
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the name fits the label cap"
    true
    (String.length first <= 63);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the base was shortened to make room"
    true
    (String.length (base_of first) < String.length k8s_name);
  Windtrap.equal
    Windtrap.bool
    ~msg:"it is still a legal name"
    true
    (is_valid_k8s_name first);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the same-second collision is still prevented"
    true
    (not (String.equal first second))
;;

let test_shortened_base_does_not_end_in_a_hyphen () =
  let k8s_name = String.make 35 'a' ^ "-" ^ "b" in
  let name =
    Sol_cli_manual_job_name.of_parts ~k8s_name ~now:1790050573. ~entropy:"seed"
  in
  Windtrap.equal Windtrap.bool ~msg:"the name fits the cap" true (String.length name <= 63);
  Windtrap.equal Windtrap.bool ~msg:"the name is legal" true (is_valid_k8s_name name);
  let base = base_of name in
  Windtrap.equal
    Windtrap.string
    ~msg:"the cut dropped the exposed hyphen"
    (String.make 35 'a')
    base;
  Windtrap.equal
    Windtrap.bool
    ~msg:"so the base does not end in a hyphen"
    false
    (String.ends_with ~suffix:"-" base)
;;

let%test "BUG-032 job-name uniqueness: shape is stable for given inputs" =
  test_shape_is_stable_for_given_inputs ()
;;

let%test "BUG-032 job-name uniqueness: same second, different runs" =
  test_same_second_different_runs_do_not_collide ()
;;

let%test "BUG-032 job-name uniqueness: mint twice in succession differs" =
  test_mint_in_immediate_succession_differs ()
;;

let%test "BUG-032 job-name uniqueness: a long base is shortened, not the entropy" =
  test_long_base_is_shortened_not_the_entropy ()
;;

let%test "BUG-032 job-name uniqueness: a shortened base stays legal" =
  test_shortened_base_does_not_end_in_a_hyphen ()
;;
