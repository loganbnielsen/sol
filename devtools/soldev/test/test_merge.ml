let check_string msg expected actual =
  Alcotest.(check string) msg expected actual

let check_option_string msg expected actual =
  Alcotest.(check (option string)) msg expected actual

let test_extract_reverted_branch_match () =
  check_option_string "extracts branch"
    (Some "EXP-023/cloud-init-kubeconfig")
    (Soldev_merge.extract_reverted_branch
       "Revert \"Merge branch 'EXP-023/cloud-init-kubeconfig'\"")

let test_extract_reverted_branch_no_match () =
  check_option_string "unrelated subject" None
    (Soldev_merge.extract_reverted_branch "EXP-023: cloud init kubeconfig")

let test_ticket_id_from_branch_with_slash () =
  check_string "takes prefix before slash"
    "EXP-023"
    (Soldev_merge.ticket_id_from_branch "EXP-023/cloud-init-kubeconfig")

let test_ticket_id_from_branch_no_slash () =
  check_string "whole string when no slash"
    "EXP-023"
    (Soldev_merge.ticket_id_from_branch "EXP-023")

let check_bool msg expected actual = Alcotest.(check bool) msg expected actual

let test_mentions_id_exact () =
  check_bool "exact token match" true
    (Soldev_merge.mentions_id ~id:"AUDIT-023" "abc123 Reapply \"Merge branch 'AUDIT-023/foo'\"")

let test_mentions_id_no_match () =
  check_bool "absent id" false
    (Soldev_merge.mentions_id ~id:"AUDIT-023" "abc123 unrelated commit")

let test_mentions_id_rejects_prefix_embedding () =
  check_bool "AUDIT-023 must not match inside CODEX_STYLE_AUDIT-023" false
    (Soldev_merge.mentions_id ~id:"AUDIT-023" "abc123 Revert \"Merge branch 'CODEX_STYLE_AUDIT-023/x'\"")

let test_mentions_id_rejects_numeric_suffix () =
  check_bool "AUDIT-2 must not match inside AUDIT-23" false
    (Soldev_merge.mentions_id ~id:"AUDIT-2" "abc123 fix AUDIT-23 typo")

(* ── review-approval sha-pinning (REFAC-077 follow-up) ───────────────────

   `pr_review_approved` must treat only the most recent SOLDEV-REVIEW
   comment as authoritative, and a PASS only counts when its embedded sha
   still matches the PR's current head — otherwise a stale PASS from an
   earlier round (superseded by a later FAIL, or by an unreviewed commit
   pushed after approval) would wrongly read as still-approved. *)

let sha_a = "aaaaaaa1111111111111111111111111111111"
let sha_b = "bbbbbbb2222222222222222222222222222222"

let pass_body sha = Printf.sprintf "SOLDEV-REVIEW: PASS %s\n\nAutomated review: pass." sha
let fail_body = "SOLDEV-REVIEW: FAIL\n\nAutomated review: changes requested.\n\n- some violation"

let approved_for_head head_sha bodies =
  match Soldev_merge.latest_review_verdict_of_bodies bodies with
  | Some (Soldev_merge.Reviewed_pass reviewed_sha) -> reviewed_sha = head_sha
  | Some Soldev_merge.Reviewed_fail | None -> false

let test_pass_then_fail_not_approved () =
  check_bool "later FAIL supersedes earlier PASS" false
    (approved_for_head sha_a [ pass_body sha_a; fail_body ])

let test_pass_on_old_sha_then_new_commit_not_approved () =
  check_bool "PASS on stale sha does not cover a later unreviewed commit" false
    (approved_for_head sha_b [ pass_body sha_a ])

let test_pass_on_current_sha_approved () =
  check_bool "PASS on the current head sha is approved" true
    (approved_for_head sha_a [ pass_body sha_a ])

(* ── stale-binary post-merge race (REFAC-075) ────────────────────────────

   Regression test for the bug that caused REFAC-072/074's false-positive
   auto-reverts: `soldev pipeline merge` used to run its post-merge test/
   baseline/DONE-move step (now `merge-finish`) inline, in the process that
   had already been running since before the merge landed. If that merge
   renamed a path this repo's own tooling depends on, the resident
   process's compiled-in path constant went stale the instant the rename
   landed, its own post-merge check failed against a path that no longer
   existed, and the built-in safety net (correctly, given what it could
   see) reverted a perfectly good merge.

   Reproduces the exact shape in a throwaway toy dune project — not the
   real soldev binary, which would need a slow real rebuild of this whole
   workspace to exercise the same way — build once, rename the file the
   binary depends on (simulating the merge), show the stale already-built
   binary now fails, then show that rebuilding from updated source (the
   fix's actual discipline: always rebuild before invoking, never trust
   the resident process) picks the rename up correctly. *)

let write_file path content =
  let oc = open_out path in
  output_string oc content; close_out oc

let in_temp_dir f =
  let orig_cwd = Sys.getcwd () in
  let tmpdir   = Filename.temp_file "soldev-race-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Sys.chdir tmpdir;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir orig_cwd;
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    f

let toy_main path_const =
  Printf.sprintf
    {|let () = let ic = open_in %S in print_string (input_line ic)|}
    path_const

let test_stale_binary_fails_after_rename () =
  in_temp_dir (fun () ->
    write_file "dune-project" "(lang dune 3.0)\n";
    Unix.mkdir "bin" 0o755;
    write_file "bin/dune" "(executable (name main))\n";
    write_file "bin/main.ml" (toy_main "scripts/marker.txt");
    Unix.mkdir "scripts" 0o755;
    write_file "scripts/marker.txt" "ok\n";
    check_bool "initial build succeeds" true
      (Sys.command "dune build 2>/dev/null" = 0);
    check_bool "runs fine before any rename" true
      (Sys.command "./_build/default/bin/main.exe >/dev/null 2>&1" = 0);
    (* Simulate a merge that renames the path the binary depends on — the
       already-built exe still has the OLD path baked in. *)
    Sys.rename "scripts" "moved_scripts";
    check_bool "stale binary fails against the renamed path (reproduces the bug)"
      true (Sys.command "./_build/default/bin/main.exe >/dev/null 2>&1" <> 0);
    (* The fix's discipline: update source to the new path (what a real
       ticket's remediation does), rebuild, then invoke a fresh binary. *)
    write_file "bin/main.ml" (toy_main "moved_scripts/marker.txt");
    check_bool "rebuild succeeds" true (Sys.command "dune build 2>/dev/null" = 0);
    check_bool "rebuilt binary succeeds against the new path (the fix)" true
      (Sys.command "./_build/default/bin/main.exe >/dev/null 2>&1" = 0))

let () =
  Alcotest.run "soldev_merge" [
    "extract_reverted_branch", [
      Alcotest.test_case "matches revert-merge subject" `Quick test_extract_reverted_branch_match;
      Alcotest.test_case "ignores unrelated subject"     `Quick test_extract_reverted_branch_no_match;
    ];
    "ticket_id_from_branch", [
      Alcotest.test_case "strips slash suffix" `Quick test_ticket_id_from_branch_with_slash;
      Alcotest.test_case "passes through when no slash" `Quick test_ticket_id_from_branch_no_slash;
    ];
    "mentions_id", [
      Alcotest.test_case "exact token match"       `Quick test_mentions_id_exact;
      Alcotest.test_case "no match"                `Quick test_mentions_id_no_match;
      Alcotest.test_case "rejects prefix embedding" `Quick test_mentions_id_rejects_prefix_embedding;
      Alcotest.test_case "rejects numeric suffix"   `Quick test_mentions_id_rejects_numeric_suffix;
    ];
    "stale-binary post-merge race", [
      Alcotest.test_case "rebuild before invoking avoids the stale-path race"
        `Quick test_stale_binary_fails_after_rename;
    ];
    "pr_review_approved sha-pinning", [
      Alcotest.test_case "PASS then FAIL is not approved"
        `Quick test_pass_then_fail_not_approved;
      Alcotest.test_case "PASS on old sha does not cover a new commit"
        `Quick test_pass_on_old_sha_then_new_commit_not_approved;
      Alcotest.test_case "PASS on current sha is approved"
        `Quick test_pass_on_current_sha_approved;
    ];
  ]
