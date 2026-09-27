let check_string msg expected actual = Alcotest.(check string) msg expected actual

let check_option_string msg expected actual =
  Alcotest.(check (option string)) msg expected actual
;;

let test_extract_reverted_branch_match () =
  check_option_string
    "extracts branch"
    (Some "EXP-023/cloud-init-kubeconfig")
    (Soldev_merge.extract_reverted_branch
       "Revert \"Merge branch 'EXP-023/cloud-init-kubeconfig'\"")
;;

let test_extract_reverted_branch_no_match () =
  check_option_string
    "unrelated subject"
    None
    (Soldev_merge.extract_reverted_branch "EXP-023: cloud init kubeconfig")
;;

let test_ticket_id_from_branch_with_slash () =
  check_string
    "takes prefix before slash"
    "EXP-023"
    (Soldev_merge.ticket_id_from_branch "EXP-023/cloud-init-kubeconfig")
;;

let test_ticket_id_from_branch_no_slash () =
  check_string
    "whole string when no slash"
    "EXP-023"
    (Soldev_merge.ticket_id_from_branch "EXP-023")
;;

let test_parse_worktree_porcelain () =
  let lines =
    [ "worktree /home/user/sol"
    ; "HEAD abc123"
    ; "branch refs/heads/main"
    ; ""
    ; "worktree /home/user/sol-FEAT-040-x"
    ; "HEAD def456"
    ; "branch refs/heads/FEAT-040/x"
    ; "bare"
    ; "detached"
    ]
  in
  let expected =
    [ "/home/user/sol", Some "main"; "/home/user/sol-FEAT-040-x", Some "FEAT-040/x" ]
  in
  Alcotest.(check (list (pair string (option string))))
    "parses worktree paths and branches"
    expected
    (Soldev_merge.parse_worktree_porcelain lines)
;;

let check_bool msg expected actual = Alcotest.(check bool) msg expected actual

let test_mentions_id_exact () =
  check_bool
    "exact token match"
    true
    (Soldev_merge.mentions_id
       ~id:"AUDIT-023"
       "abc123 Reapply \"Merge branch 'AUDIT-023/foo'\"")
;;

let test_mentions_id_no_match () =
  check_bool
    "absent id"
    false
    (Soldev_merge.mentions_id ~id:"AUDIT-023" "abc123 unrelated commit")
;;

let test_mentions_id_rejects_prefix_embedding () =
  check_bool
    "AUDIT-023 must not match inside CODEX_STYLE_AUDIT-023"
    false
    (Soldev_merge.mentions_id
       ~id:"AUDIT-023"
       "abc123 Revert \"Merge branch 'CODEX_STYLE_AUDIT-023/x'\"")
;;

let test_mentions_id_rejects_numeric_suffix () =
  check_bool
    "AUDIT-2 must not match inside AUDIT-23"
    false
    (Soldev_merge.mentions_id ~id:"AUDIT-2" "abc123 fix AUDIT-23 typo")
;;

let sha_a = "aaaaaaa1111111111111111111111111111111"
let sha_b = "bbbbbbb2222222222222222222222222222222"
let pass_body sha = Printf.sprintf "SOLDEV-REVIEW: PASS %s\n\nAutomated review: pass." sha

let fail_body =
  "SOLDEV-REVIEW: FAIL\n\nAutomated review: changes requested.\n\n- some violation"
;;

let approved_for_head head_sha bodies =
  match Soldev_merge.latest_review_verdict_of_bodies bodies with
  | Some (Soldev_merge.Reviewed_pass reviewed_sha) -> reviewed_sha = head_sha
  | Some Soldev_merge.Reviewed_fail | None -> false
;;

let test_pass_then_fail_not_approved () =
  check_bool
    "later FAIL supersedes earlier PASS"
    false
    (approved_for_head sha_a [ pass_body sha_a; fail_body ])
;;

let test_pass_on_old_sha_then_new_commit_not_approved () =
  check_bool
    "PASS on stale sha does not cover a later unreviewed commit"
    false
    (approved_for_head sha_b [ pass_body sha_a ])
;;

let test_pass_on_current_sha_approved () =
  check_bool
    "PASS on the current head sha is approved"
    true
    (approved_for_head sha_a [ pass_body sha_a ])
;;

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let in_temp_dir f =
  let orig_cwd = Sys.getcwd () in
  let tmpdir = Filename.temp_file "soldev-race-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Sys.chdir tmpdir;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir orig_cwd;
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    f
;;

let toy_main path_const =
  Printf.sprintf
    {|let () = let ic = open_in %S in print_string (input_line ic)|}
    path_const
;;

let test_stale_binary_fails_after_rename () =
  in_temp_dir (fun () ->
    write_file "dune-project" "(lang dune 3.0)\n";
    Unix.mkdir "bin" 0o755;
    write_file "bin/dune" "(executable (name main))\n";
    write_file "bin/main.ml" (toy_main "scripts/marker.txt");
    Unix.mkdir "scripts" 0o755;
    write_file "scripts/marker.txt" "ok\n";
    check_bool "initial build succeeds" true (Sys.command "dune build 2>/dev/null" = 0);
    check_bool
      "runs fine before any rename"
      true
      (Sys.command "./_build/default/bin/main.exe >/dev/null 2>&1" = 0);
    Sys.rename "scripts" "moved_scripts";
    check_bool
      "stale binary fails against the renamed path (reproduces the bug)"
      true
      (Sys.command "./_build/default/bin/main.exe >/dev/null 2>&1" <> 0);
    write_file "bin/main.ml" (toy_main "moved_scripts/marker.txt");
    check_bool "rebuild succeeds" true (Sys.command "dune build 2>/dev/null" = 0);
    check_bool
      "rebuilt binary succeeds against the new path (the fix)"
      true
      (Sys.command "./_build/default/bin/main.exe >/dev/null 2>&1" = 0))
;;

let test_post_merge_action_of_rc () =
  let show = function
    | Soldev_merge.Record_baseline -> "record"
    | Soldev_merge.Record_baseline_after_perf_regression -> "record-perf"
    | Soldev_merge.Report_local_failure rc -> Printf.sprintf "report:%d" rc
  in
  Alcotest.(check string)
    "0 is a clean suite"
    "record"
    (show (Soldev_merge.post_merge_action_of_rc 0));
  Alcotest.(check string)
    "2 is the perf-ratio verdict, informational"
    "record-perf"
    (show (Soldev_merge.post_merge_action_of_rc 2));
  Alcotest.(check string)
    "1 is a failure to report, never a revert"
    "report:1"
    (show (Soldev_merge.post_merge_action_of_rc 1));
  Alcotest.(check string)
    "an unrunnable suite is not a merged success"
    "report:127"
    (show (Soldev_merge.post_merge_action_of_rc 127));
  Alcotest.(check string)
    "and neither is any other non-zero"
    "report:3"
    (show (Soldev_merge.post_merge_action_of_rc 3))
;;

let git args = Sys.command (Printf.sprintf "git %s >/dev/null 2>&1" args) = 0
let git_ok args = check_bool (Printf.sprintf "git %s succeeds" args) true (git args)

let rev_parse ref =
  let ic = Unix.open_process_in (Printf.sprintf "git rev-parse %s 2>/dev/null" ref) in
  let line = In_channel.input_line ic |> Option.value ~default:"" in
  ignore (Unix.close_process_in ic);
  String.trim line
;;

let unpushed_of branch =
  match Soldev_merge.worktree_snapshot_of_entry (Sys.getcwd (), Some branch) with
  | Some (snapshot : Soldev_merge.worktree_snapshot) -> snapshot.ws_unpushed
  | None -> Alcotest.fail "expected a worktree snapshot"
;;

let test_unpushed_annotation_asks_git () =
  in_temp_dir (fun () ->
    git_ok "init -q";
    git_ok "config user.email soldev@test";
    git_ok "config user.name soldev";
    write_file "f.txt" "a\n";
    git_ok "add f.txt";
    git_ok "commit -qm a";
    let a = rev_parse "HEAD" in
    git_ok (Printf.sprintf "update-ref refs/remotes/origin/main %s" a);
    check_bool "at origin/main is not unpushed" false (unpushed_of "work");
    write_file "f.txt" "b\n";
    git_ok "add f.txt";
    git_ok "commit -qm b";
    let b = rev_parse "HEAD" in
    check_bool "ahead of origin/main is unpushed" true (unpushed_of "work");
    git_ok (Printf.sprintf "update-ref refs/remotes/origin/main %s" b);
    git_ok (Printf.sprintf "checkout -q -B work %s" a);
    check_bool "behind origin/main is not unpushed" false (unpushed_of "work");
    git_ok (Printf.sprintf "update-ref refs/remotes/origin/work %s" a);
    check_bool "equal to its upstream is not unpushed" false (unpushed_of "work");
    git_ok (Printf.sprintf "checkout -q -B work %s" b);
    check_bool "ahead of its upstream is unpushed" true (unpushed_of "work");
    git_ok (Printf.sprintf "update-ref refs/remotes/origin/work %s" b);
    git_ok (Printf.sprintf "checkout -q -B work %s" a);
    check_bool "behind its upstream is not unpushed" false (unpushed_of "work");
    git_ok "update-ref -d refs/remotes/origin/main";
    git_ok "update-ref -d refs/remotes/origin/work";
    check_bool "an unresolvable ref stays unpushed" true (unpushed_of "work"))
;;

let () =
  Alcotest.run
    "soldev_merge"
    [ ( "extract_reverted_branch"
      , [ Alcotest.test_case
            "matches revert-merge subject"
            `Quick
            test_extract_reverted_branch_match
        ; Alcotest.test_case
            "ignores unrelated subject"
            `Quick
            test_extract_reverted_branch_no_match
        ] )
    ; ( "ticket_id_from_branch"
      , [ Alcotest.test_case
            "strips slash suffix"
            `Quick
            test_ticket_id_from_branch_with_slash
        ; Alcotest.test_case
            "passes through when no slash"
            `Quick
            test_ticket_id_from_branch_no_slash
        ] )
    ; ( "worktree_porcelain"
      , [ Alcotest.test_case
            "parses paths and branches"
            `Quick
            test_parse_worktree_porcelain
        ] )
    ; ( "worktree unpushed annotation (BUG-063)"
      , [ Alcotest.test_case
            "asks git for commits, not shas"
            `Quick
            test_unpushed_annotation_asks_git
        ] )
    ; ( "mentions_id"
      , [ Alcotest.test_case "exact token match" `Quick test_mentions_id_exact
        ; Alcotest.test_case "no match" `Quick test_mentions_id_no_match
        ; Alcotest.test_case
            "rejects prefix embedding"
            `Quick
            test_mentions_id_rejects_prefix_embedding
        ; Alcotest.test_case
            "rejects numeric suffix"
            `Quick
            test_mentions_id_rejects_numeric_suffix
        ] )
    ; ( "stale-binary post-merge race"
      , [ Alcotest.test_case
            "rebuild before invoking avoids the stale-path race"
            `Quick
            test_stale_binary_fails_after_rename
        ] )
    ; ( "post_merge_action_of_rc"
      , [ Alcotest.test_case
            "a local post-merge failure is reported, never acted on"
            `Quick
            test_post_merge_action_of_rc
        ] )
    ; ( "pr_review_approved sha-pinning"
      , [ Alcotest.test_case
            "PASS then FAIL is not approved"
            `Quick
            test_pass_then_fail_not_approved
        ; Alcotest.test_case
            "PASS on old sha does not cover a new commit"
            `Quick
            test_pass_on_old_sha_then_new_commit_not_approved
        ; Alcotest.test_case
            "PASS on current sha is approved"
            `Quick
            test_pass_on_current_sha_approved
        ] )
    ]
;;
