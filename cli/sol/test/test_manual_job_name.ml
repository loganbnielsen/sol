(* BUG-032: a manual run's Job name must be unique per invocation.

   The regression is a name collision between two `sol fn run` invocations of the
   same `-fn` in the same wall-clock second: the old
   `<k8s_name>-manual-<epoch seconds>` form made them identical, and the second
   `kubectl create job` failed with AlreadyExists. INFRA-016 hit it immediately by
   firing several at once.

   Tested at two levels: [of_parts] pins the shape deterministically (clock and
   entropy supplied), and [mint] is exercised the way the acceptance criterion asks —
   called twice in immediate succession, asserting the results differ. *)

let is_lower_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
let all_lower_hex s = String.length s > 0 && String.for_all is_lower_hex s

(* The command's own validator, so "is this a legal Kubernetes name" is not
   re-implemented here. *)
let is_valid_k8s_name s =
  match Sol_cli_kubernetes_name.validate_dns_label s with
  | Ok () -> true
  | Error _ -> false
;;

(* Everything before the "-manual-" marker, i.e. the part the 63-cap shortens. The
   base itself contains hyphens, so the marker is what delimits it. *)
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
  Alcotest.(check bool)
    "prefix is <k8s_name>-manual-<seconds>-"
    true
    (String.starts_with ~prefix:expected_prefix name);
  Alcotest.(check bool)
    "and the tail is hex entropy"
    true
    (all_lower_hex (String.sub name (String.length expected_prefix) 8));
  Alcotest.(check string)
    "the same inputs give the same name"
    name
    (Sol_cli_manual_job_name.of_parts
       ~k8s_name:"order-svc"
       ~now:1790050573.
       ~entropy:"seed")
;;

(* The defect itself, at the pure level: same second, different runs. *)
let test_same_second_different_runs_do_not_collide () =
  let at = 1790050573. in
  let first =
    Sol_cli_manual_job_name.of_parts ~k8s_name:"order-svc" ~now:at ~entropy:"run-one"
  in
  let second =
    Sol_cli_manual_job_name.of_parts ~k8s_name:"order-svc" ~now:at ~entropy:"run-two"
  in
  Alcotest.(check bool)
    "two runs in the same second produce different names"
    true
    (not (String.equal first second))
;;

(* What the acceptance criterion asks for directly. *)
let test_mint_in_immediate_succession_differs () =
  let first = Sol_cli_manual_job_name.mint ~k8s_name:"order-svc" in
  let second = Sol_cli_manual_job_name.mint ~k8s_name:"order-svc" in
  Alcotest.(check bool)
    "two successive mint calls differ"
    true
    (not (String.equal first second));
  Alcotest.(check bool) "and both are legal names" true (is_valid_k8s_name first);
  Alcotest.(check bool) "and both are legal names" true (is_valid_k8s_name second)
;;

(* Kubernetes copies the Job name into the pod's `job-name` label, and a label value
   is capped at 63 characters — so the name must fit, and it must fit *without*
   truncating the entropy off the end, which would restore the collision. *)
let test_long_base_is_shortened_not_the_entropy () =
  let k8s_name = String.make 63 'a' in
  let first =
    Sol_cli_manual_job_name.of_parts ~k8s_name ~now:1790050573. ~entropy:"run-one"
  in
  let second =
    Sol_cli_manual_job_name.of_parts ~k8s_name ~now:1790050573. ~entropy:"run-two"
  in
  Alcotest.(check bool) "the name fits the label cap" true (String.length first <= 63);
  Alcotest.(check bool)
    "the base was shortened to make room"
    true
    (String.length (base_of first) < String.length k8s_name);
  Alcotest.(check bool) "it is still a legal name" true (is_valid_k8s_name first);
  Alcotest.(check bool)
    "and the same-second collision is still prevented"
    true
    (not (String.equal first second))
;;

(* A cut can land on a hyphen; the result must still be a legal name (and so must
   not end its base with one). *)
let test_shortened_base_does_not_end_in_a_hyphen () =
  (* 37 characters, so the 63-cap cut lands exactly on the hyphen at index 35. *)
  let k8s_name = String.make 35 'a' ^ "-" ^ "b" in
  let name =
    Sol_cli_manual_job_name.of_parts ~k8s_name ~now:1790050573. ~entropy:"seed"
  in
  Alcotest.(check bool) "the name fits the cap" true (String.length name <= 63);
  Alcotest.(check bool) "the name is legal" true (is_valid_k8s_name name);
  (* The base is what precedes the "-manual-" marker; the suffix's own leading
     hyphen must not sit next to a hyphen the cut exposed. *)
  let base = base_of name in
  Alcotest.(check string) "the cut dropped the exposed hyphen" (String.make 35 'a') base;
  Alcotest.(check bool)
    "so the base does not end in a hyphen"
    false
    (String.ends_with ~suffix:"-" base)
;;

let () =
  Alcotest.run
    "manual_job_name"
    [ ( "BUG-032 job-name uniqueness"
      , [ Alcotest.test_case
            "shape is stable for given inputs"
            `Quick
            test_shape_is_stable_for_given_inputs
        ; Alcotest.test_case
            "same second, different runs"
            `Quick
            test_same_second_different_runs_do_not_collide
        ; Alcotest.test_case
            "mint twice in succession differs"
            `Quick
            test_mint_in_immediate_succession_differs
        ; Alcotest.test_case
            "a long base is shortened, not the entropy"
            `Quick
            test_long_base_is_shortened_not_the_entropy
        ; Alcotest.test_case
            "a shortened base stays legal"
            `Quick
            test_shortened_base_does_not_end_in_a_hyphen
        ] )
    ]
;;
