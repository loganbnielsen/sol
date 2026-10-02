let entry release_id created_at = release_id, created_at
let ts n = Printf.sprintf "2026-01-01T00:00:%02dZ" n

let select ~keep ~current ~previous entries =
  match Sol_cli_release_retention.select ~keep ~current ~previous entries with
  | Ok ids -> ids
  | Error msg -> Alcotest.fail ("unexpected unreadable previous: " ^ msg)
;;

let test_default_window () =
  Alcotest.(check int) "DEC-018 default" 20 Sol_cli_release_retention.default_keep
;;

let test_under_limit_prunes_nothing () =
  let entries = [ entry "r-1" (ts 1); entry "r-2" (ts 2); entry "r-3" (ts 3) ] in
  Alcotest.(check (list string))
    "nothing to prune"
    []
    (select ~keep:3 ~current:"r-3" ~previous:(Known "r-2") entries)
;;

let test_prunes_oldest_beyond_the_window () =
  let entries =
    [ entry "r-1" (ts 1)
    ; entry "r-2" (ts 2)
    ; entry "r-3" (ts 3)
    ; entry "r-4" (ts 4)
    ; entry "r-5" (ts 5)
    ]
  in
  Alcotest.(check (list string))
    "oldest three, oldest first"
    [ "r-1"; "r-2"; "r-3" ]
    (select ~keep:2 ~current:"r-5" ~previous:(Known "r-4") entries)
;;

let test_current_and_previous_are_never_pruned () =
  let entries =
    [ entry "r-1" (ts 1)
    ; entry "r-2" (ts 2)
    ; entry "r-3" (ts 3)
    ; entry "r-4" (ts 4)
    ; entry "r-5" (ts 5)
    ]
  in
  Alcotest.(check (list string))
    "only r-3 is prunable"
    [ "r-3" ]
    (select ~keep:2 ~current:"r-1" ~previous:(Known "r-2") entries)
;;

let test_none_yet_does_not_protect_a_previous () =
  let entries =
    [ entry "r-1" (ts 1)
    ; entry "r-2" (ts 2)
    ; entry "r-3" (ts 3)
    ; entry "r-4" (ts 4)
    ; entry "r-5" (ts 5)
    ]
  in
  Alcotest.(check (list string))
    "r-2 and r-3 are prunable when nothing displaced the current release"
    [ "r-2"; "r-3" ]
    (select ~keep:2 ~current:"r-1" ~previous:None_yet entries)
;;

let test_unreadable_previous_refuses_to_prune () =
  let entries = [ entry "r-1" (ts 1); entry "r-2" (ts 2); entry "r-3" (ts 3) ] in
  Alcotest.(check (result (list string) string))
    "refuses, carrying the cause"
    (Error "could not determine the previous release: connection refused")
    (Sol_cli_release_retention.select
       ~keep:1
       ~current:"r-3"
       ~previous:(Unreadable "connection refused")
       entries)
;;

let test_duplicate_deploys_collapse () =
  let entries =
    [ entry "r-1" (ts 1); entry "r-2" (ts 2); entry "r-3" (ts 3); entry "r-1" (ts 4) ]
  in
  Alcotest.(check (list string))
    "r-2 pruned, not r-1"
    [ "r-2" ]
    (select ~keep:2 ~current:"r-1" ~previous:None_yet entries)
;;

let test_tie_break_is_deterministic () =
  let entries = [ entry "r-b" (ts 1); entry "r-a" (ts 1) ] in
  Alcotest.(check (list string))
    "same result regardless of input order"
    (select ~keep:1 ~current:"r-b" ~previous:None_yet entries)
    (select ~keep:1 ~current:"r-b" ~previous:None_yet (List.rev entries))
;;

let test_keep_zero_still_protects_current_and_previous () =
  let entries = [ entry "r-1" (ts 1); entry "r-2" (ts 2); entry "r-3" (ts 3) ] in
  Alcotest.(check (list string))
    "everything but current/previous"
    [ "r-1" ]
    (select ~keep:0 ~current:"r-3" ~previous:(Known "r-2") entries)
;;

let%test "select: default window" = test_default_window ()
let%test "select: under limit" = test_under_limit_prunes_nothing ()
let%test "select: duplicate deploys collapse" = test_duplicate_deploys_collapse ()
let%test "select: tie-break is deterministic" = test_tie_break_is_deterministic ()
