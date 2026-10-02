let test_the_boundary_is_read_while_the_lease_is_held () =
  let boundary = ref "old" in
  let applied = ref None in
  let result =
    Sol_cli_boundary_epoch.run
      { acquire_lease =
          (fun f ->
            boundary := "new";
            f ())
      ; read_boundary_holding = (fun () -> Ok !boundary)
      ; apply =
          (fun () lease_boundary ->
            applied := Some lease_boundary;
            Ok ())
      }
  in
  (match result with
   | Ok () -> ()
   | Error message -> Alcotest.failf "the epoch must run: %s" message);
  Alcotest.(check (option string))
    "the release inherits the boundary that is current once the lease is held"
    (Some "new")
    !applied
;;

let test_a_boundary_read_before_the_lease_would_see_the_stale_one () =
  let boundary = ref "old" in
  let stale = !boundary in
  boundary := "new";
  Alcotest.(check bool)
    "reading the pointer before acquiring the lease yields the stale boundary"
    false
    (String.equal stale !boundary)
;;

let test_an_unreadable_boundary_refuses_before_applying () =
  let applied = ref false in
  let result =
    Sol_cli_boundary_epoch.run
      { acquire_lease = (fun f -> f ())
      ; read_boundary_holding =
          (fun () -> Error "the current workspace boundary could not be read")
      ; apply =
          (fun () _ ->
            applied := true;
            Ok ())
      }
  in
  (match result with
   | Ok () -> Alcotest.fail "an unreadable boundary must refuse"
   | Error message ->
     Alcotest.(check string)
       "the reason is carried"
       "the current workspace boundary could not be read"
       message);
  Alcotest.(check bool) "nothing was applied" false !applied
;;

let%test "one boundary epoch per mutation: the boundary is read while the lease is held" =
  test_the_boundary_is_read_while_the_lease_is_held ()
;;

let%test
    "one boundary epoch per mutation: a read before the lease would see the stale \
     boundary"
  =
  test_a_boundary_read_before_the_lease_would_see_the_stale_one ()
;;

let%test "one boundary epoch per mutation: an unreadable boundary refuses before applying"
  =
  test_an_unreadable_boundary_refuses_before_applying ()
;;
