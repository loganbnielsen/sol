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

let test_required_checks () =
  let parse text = Soldev_merge.checks_green_of_json (Yojson.Basic.from_string text) in
  check_bool "successful required check" true (parse {|[{"bucket":"pass"}]|});
  List.iter
    (fun json -> check_bool ("not green: " ^ json) false (parse json))
    [ "[]"
    ; "{}"
    ; {|[{"bucket":"pending"}]|}
    ; {|[{"bucket":"fail"}]|}
    ; {|[{"bucket":"pass"},{"bucket":"cancel"}]|}
    ; {|[{"bucket":"skipping"}]|}
    ; "[null]"
    ; {|[{}]|}
    ]
;;

let test_merge_command () =
  let pr : Soldev_merge.pr_info =
    { pr_number = 1
    ; pr_url = "https://github.com/example/sol/pull/1"
    ; pr_branch = "BUG-001/test"
    ; pr_head_sha = "abc123"
    ; pr_draft = false
    }
  in
  let immediate = Soldev_merge.merge_command ~auto_merge:false pr in
  check_string
    "immediate merge pins head and never bypasses checks or deletes a tree"
    "gh pr merge 'https://github.com/example/sol/pull/1' --squash --match-head-commit \
     'abc123'"
    immediate;
  check_string
    "auto-merge uses GitHub rather than a polling loop"
    (immediate ^ " --auto")
    (Soldev_merge.merge_command ~auto_merge:true pr)
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

let test_merge_without_review_marker () =
  in_temp_dir (fun () ->
    let old_path = Sys.getenv "PATH" in
    let dir = Sys.getcwd () in
    Unix.mkdir "internal" 0o755;
    Unix.mkdir "internal/pipeline" 0o755;
    Unix.mkdir "internal/pipeline/tickets" 0o755;
    List.iter
      (fun state -> Unix.mkdir ("internal/pipeline/tickets/" ^ state) 0o755)
      [ "BACKLOG"; "READY_FOR_ENGINEERING"; "DONE" ];
    write_file
      "internal/pipeline/tickets/DONE/BUG-001.md"
      "---\n\
       id: BUG-001\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       A completed ticket\n\n\
       **Depends on:** None.\n";
    write_file
      "gh"
      "#!/bin/sh\n\
       if [ \"$2\" = checks ]; then cat checks.json; else printf '%s\\n' \"$*\" >> \
       merges; fi\n";
    Unix.chmod "gh" 0o755;
    Unix.putenv "PATH" (dir ^ ":" ^ old_path);
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         let pr : Soldev_merge.pr_info =
           { pr_number = 1
           ; pr_url = "https://example.test/pr/1"
           ; pr_branch = "BUG-001/test"
           ; pr_head_sha = "abc123"
           ; pr_draft = false
           }
         in
         let request ~auto_merge pr =
           ignore
             (Soldev_merge.merge_candidates ~dry_run:false ~auto_merge [ "BUG-001", pr ])
         in
         List.iter
           (fun json ->
              write_file "checks.json" json;
              request ~auto_merge:false pr;
              check_bool "no unsafe immediate merge" false (Sys.file_exists "merges"))
           [ "[]"; {|[{"bucket":"pending"}]|}; {|[{"bucket":"fail"}]|}; "not JSON" ];
         write_file "checks.json" {|[{"bucket":"pass"}]|};
         request ~auto_merge:true { pr with pr_draft = true };
         check_bool "draft cannot queue auto-merge" false (Sys.file_exists "merges");
         request ~auto_merge:false pr;
         check_bool
           "green required CI merges without any review marker"
           true
           (Sys.file_exists "merges");
         Sys.remove "merges";
         write_file "checks.json" {|[{"bucket":"pending"}]|};
         request ~auto_merge:true pr;
         let command = In_channel.with_open_text "merges" In_channel.input_all in
         check_bool
           "pending CI queues native auto-merge"
           true
           (String.ends_with ~suffix:" --auto\n" command)))
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
    ; ( "CI-gated merges"
      , [ Alcotest.test_case
            "required checks are successful and nonempty"
            `Quick
            test_required_checks
        ; Alcotest.test_case "head-pinned native merge commands" `Quick test_merge_command
        ; Alcotest.test_case
            "merge and queue gates without review markers"
            `Quick
            test_merge_without_review_marker
        ] )
    ]
;;
