(* FEAT-072 retention selection: pure window/protection logic. *)

let entry release_id created_at = release_id, created_at

(* Lexicographically sortable RFC3339 timestamps. *)
let ts n = Printf.sprintf "2026-01-01T00:00:%02dZ" n

let contains haystack needle =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0
;;

(* [select] answers [Error] only when the previous-release input is unreadable;
   every case here passes a usable one, so the [Ok] payload is the subject. *)
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

(* A rollback can leave the pointer on an old release; retention must still keep
   it and the release it displaced, even though both are outside the newest
   [keep]. *)
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

(* The complement of the test above, and what makes [previous] load-bearing: with
   nothing displacing the current release, the record the other test protects is
   prunable. *)
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

(* FND-0025: an unreadable previous-release input must not silently read as "no
   previous release" — that would prune the record `sol rollback` restores, and
   `--keep-releases` promises it is never pruned. The selection must refuse and
   say why. *)
let test_unreadable_previous_refuses_to_prune () =
  let entries = [ entry "r-1" (ts 1); entry "r-2" (ts 2); entry "r-3" (ts 3) ] in
  Alcotest.(check bool)
    "refuses, carrying the reason"
    true
    (match
       Sol_cli_release_retention.select
         ~keep:1
         ~current:"r-3"
         ~previous:(Unreadable "connection refused")
         entries
     with
     | Error msg -> contains msg "connection refused"
     | Ok _ -> false)
;;

(* Two deploys of identical content are one release. The window counts distinct
   releases, keeping the newest appearance. *)
let test_duplicate_deploys_collapse () =
  let entries =
    [ entry "r-1" (ts 1)
    ; entry "r-2" (ts 2)
    ; entry "r-3" (ts 3)
    ; entry "r-1" (ts 4) (* redeployed later *)
    ]
  in
  Alcotest.(check (list string))
    "r-2 pruned, not r-1"
    [ "r-2" ]
    (select ~keep:2 ~current:"r-1" ~previous:None_yet entries)
;;

(* Equal timestamps still produce a deterministic result (id tie-break). *)
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

let () =
  Alcotest.run
    "release_retention"
    [ ( "select"
      , [ Alcotest.test_case "default window" `Quick test_default_window
        ; Alcotest.test_case "under limit" `Quick test_under_limit_prunes_nothing
        ; "prunes oldest beyond window", `Quick, test_prunes_oldest_beyond_the_window
        ; ( "never prunes current or previous"
          , `Quick
          , test_current_and_previous_are_never_pruned )
        ; ( "no previous protects nothing extra"
          , `Quick
          , test_none_yet_does_not_protect_a_previous )
        ; ( "unreadable previous refuses to prune"
          , `Quick
          , test_unreadable_previous_refuses_to_prune )
        ; Alcotest.test_case
            "duplicate deploys collapse"
            `Quick
            test_duplicate_deploys_collapse
        ; Alcotest.test_case
            "tie-break is deterministic"
            `Quick
            test_tie_break_is_deterministic
        ; ( "keep 0 still protects current/previous"
          , `Quick
          , test_keep_zero_still_protects_current_and_previous )
        ] )
    ]
;;
