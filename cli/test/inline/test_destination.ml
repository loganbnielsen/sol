let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)
let context_name (ctx : Sol_cli_kube_destination.context) = ctx.destination.context

let write path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/"
  then ()
  else if Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let with_temp_dir f =
  let dir = Filename.temp_file "sol-destination-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       f ())
;;

let write_base () = write "sol.yml" "project: pluto\n"

let write_target kube_context =
  mkdir_p "sol/prod/aws";
  Targets_fixture.write
    ~target:"prod/aws/us-east-1"
    (Printf.sprintf
       "target:\n  cluster_name: prod-cluster\n%s"
       (match kube_context with
        | Some c -> Printf.sprintf "  kube_context: %s\n" c
        | None -> ""))
;;

let ok_or_fail = function
  | Ok value -> value
  | Error message -> Alcotest.fail ("unexpected error: " ^ message)
;;

let error_or_fail = function
  | Error message -> message
  | Ok _ -> Alcotest.fail "expected the resolution to fail closed"
;;

let test_local_entry_point_is_the_literal_local_cluster () =
  let ctx =
    ok_or_fail (Sol_cli_destination.resolve ~command:"status" ~local:true ~target:None)
  in
  check_string "local destination" "k3d-sol-local" (context_name ctx)
;;

let test_local_wins_even_if_a_target_is_supplied () =
  let ctx =
    ok_or_fail
      (Sol_cli_destination.resolve
         ~command:"status"
         ~local:true
         ~target:(Some "prod/aws/us-east-1"))
  in
  check_string "local destination" "k3d-sol-local" (context_name ctx)
;;

let test_top_level_without_target_fails_closed_naming_local_form () =
  let message =
    error_or_fail
      (Sol_cli_destination.resolve ~command:"status" ~local:false ~target:None)
  in
  check_bool "names --target" true (Sol_cli_string.contains ~needle:"--target" message);
  check_bool
    "names the local spelling"
    true
    (Sol_cli_string.contains ~needle:"sol local status" message)
;;

let test_local_form_message_is_command_specific () =
  let message =
    error_or_fail
      (Sol_cli_destination.resolve ~command:"rollback" ~local:false ~target:None)
  in
  check_bool
    "names rollback's local spelling, not status's"
    true
    (Sol_cli_string.contains ~needle:"sol local rollback" message)
;;

let test_top_level_target_supplies_the_destination () =
  with_temp_dir (fun () ->
    write_base ();
    write_target (Some "prod-cluster");
    let ctx =
      ok_or_fail
        (Sol_cli_destination.resolve
           ~command:"status"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_string "target's destination" "prod-cluster" (context_name ctx))
;;

let test_target_without_context_fails_closed () =
  with_temp_dir (fun () ->
    write_base ();
    write_target None;
    let message =
      error_or_fail
        (Sol_cli_destination.resolve
           ~command:"status"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_bool
      "the message says what to add"
      true
      (Sol_cli_string.contains ~needle:"kube_context" message))
;;

let test_reserved_local_target_points_at_local_form () =
  with_temp_dir (fun () ->
    write_base ();
    write_target (Some "k3d-sol-local");
    let message =
      error_or_fail
        (Sol_cli_destination.resolve
           ~command:"status"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_bool
      "redirects to the local spelling"
      true
      (Sol_cli_string.contains ~needle:"sol local <command>" message))
;;

let test_resolution_is_deterministic () =
  let resolve () =
    Sol_cli_destination.resolve ~command:"logs" ~local:false ~target:None
  in
  match resolve (), resolve () with
  | Error a, Error b -> check_string "same error twice" a b
  | Ok a, Ok b -> check_string "same context twice" (context_name a) (context_name b)
  | _ -> Alcotest.fail "resolution disagreed with itself"
;;

let%test "seam: local entry point is the literal local cluster" =
  test_local_entry_point_is_the_literal_local_cluster ()
;;

let%test "seam: local wins even if a target is supplied" =
  test_local_wins_even_if_a_target_is_supplied ()
;;

let%test "seam: top-level without target fails closed naming local form" =
  test_top_level_without_target_fails_closed_naming_local_form ()
;;

let%test "seam: the local spelling in the message is command-specific" =
  test_local_form_message_is_command_specific ()
;;

let%test "seam: top-level target supplies the destination" =
  test_top_level_target_supplies_the_destination ()
;;

let%test "seam: target without a kube_context fails closed" =
  test_target_without_context_fails_closed ()
;;

let%test "seam: a reserved-local target points at the local form" =
  test_reserved_local_target_points_at_local_form ()
;;

let%test "seam: resolution is deterministic" = test_resolution_is_deterministic ()
