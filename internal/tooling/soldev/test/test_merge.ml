let check_string msg expected actual = Alcotest.(check string) msg expected actual

let check_option_string msg expected actual =
  Alcotest.(check (option string)) msg expected actual
;;

let check_option_int msg expected actual =
  Alcotest.(check (option int)) msg expected actual
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

let test_pinned_head_sha_prefers_the_branch_ref () =
  check_string
    "the ref the transport advertises now, not the payload's older value"
    "fresh456"
    (Soldev_merge.pinned_head_sha
       ~listed:"stale123"
       ~cross_repository:false
       (Some "fresh456\trefs/heads/BUG-001/test\n"))
;;

let test_pinned_head_sha_keeps_the_listed_sha_when_it_cannot_be_improved () =
  check_string
    "a cross-repository PR's head is not this repository's ref"
    "listed123"
    (Soldev_merge.pinned_head_sha
       ~listed:"listed123"
       ~cross_repository:true
       (Some "other456\trefs/heads/BUG-001/test\n"));
  check_string
    "an unreadable ref query changes nothing"
    "listed123"
    (Soldev_merge.pinned_head_sha ~listed:"listed123" ~cross_repository:false None);
  check_string
    "an empty answer changes nothing"
    "listed123"
    (Soldev_merge.pinned_head_sha ~listed:"listed123" ~cross_repository:false (Some ""));
  check_string
    "an ambiguous answer changes nothing"
    "listed123"
    (Soldev_merge.pinned_head_sha
       ~listed:"listed123"
       ~cross_repository:false
       (Some "a\trefs/heads/x\nb\trefs/heads/y\n"));
  check_string
    "a line with no sha changes nothing"
    "listed123"
    (Soldev_merge.pinned_head_sha
       ~listed:"listed123"
       ~cross_repository:false
       (Some "\trefs/heads/BUG-001/test\n"))
;;

let outcome_of ~errors ~refusals ~targeted =
  match Soldev_merge.merge_outcome ~errors ~refusals ~targeted with
  | Soldev_merge.All_requested -> "all_requested"
  | Soldev_merge.Some_requests_failed -> "some_requests_failed"
  | Soldev_merge.Nothing_requested -> "nothing_requested"
;;

let test_a_skipped_targeted_merge_is_not_a_success () =
  check_string
    "a refusal on a targeted invocation is a failure, not a quiet success"
    "nothing_requested"
    (outcome_of ~errors:0 ~refusals:1 ~targeted:true);
  check_string
    "a sweep may skip what cannot be queued"
    "all_requested"
    (outcome_of ~errors:0 ~refusals:3 ~targeted:false);
  check_string
    "a request that failed to queue outranks the skip"
    "some_requests_failed"
    (outcome_of ~errors:1 ~refusals:1 ~targeted:true);
  check_string
    "no refusals, nothing to report"
    "all_requested"
    (outcome_of ~errors:0 ~refusals:0 ~targeted:true)
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

let contains ~needle haystack =
  let n = String.length needle
  and m = String.length haystack in
  let rec go i = i + n <= m && (String.sub haystack i n = needle || go (i + 1)) in
  go 0
;;

let repo_pr ?(state = "MERGED") ?commit number branch =
  { Soldev_merge.repo_pr_number = number
  ; repo_pr_url = Printf.sprintf "https://github.com/loganbnielsen/sol/pull/%d" number
  ; repo_pr_branch = branch
  ; repo_pr_state = state
  ; repo_pr_commit = commit
  }
;;

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

let test_pr_info =
  { Soldev_merge.pr_number = 1
  ; pr_url = "https://github.com/example/sol/pull/1"
  ; pr_branch = "BUG-001/test"
  ; pr_base_ref = "main"
  ; pr_head_sha = "abc123"
  ; pr_draft = false
  ; pr_cross_repository = false
  }
;;

let test_merge_command () =
  let immediate = Soldev_merge.merge_command ~mode:Soldev_merge.Immediate test_pr_info in
  check_string
    "immediate merge pins head and never bypasses checks or deletes a tree"
    "gh pr merge 'https://github.com/example/sol/pull/1' --squash --match-head-commit \
     'abc123'"
    immediate;
  check_string
    "auto-merge uses GitHub rather than a polling loop"
    (immediate ^ " --auto")
    (Soldev_merge.merge_command ~mode:Soldev_merge.Auto_merge test_pr_info)
;;

let test_default_mode_queues_auto_merge () =
  check_bool
    "the flag default — no --immediate — is auto-merge"
    true
    (Soldev_merge.merge_mode_of_flag ~immediate:false = Soldev_merge.Auto_merge);
  check_bool
    "--immediate is the opt-in"
    true
    (Soldev_merge.merge_mode_of_flag ~immediate:true = Soldev_merge.Immediate);
  check_bool
    "the default command queues auto-merge"
    true
    (String.ends_with
       ~suffix:" --auto"
       (Soldev_merge.merge_command
          ~mode:(Soldev_merge.merge_mode_of_flag ~immediate:false)
          test_pr_info))
;;

let test_parse_pr_number () =
  let parse = Soldev_merge.parse_pr_number in
  List.iter
    (fun (input, expected) ->
       check_option_int ("accepts " ^ input) (Some expected) (parse input))
    [ "42", 42
    ; "#42", 42
    ; " 42 ", 42
    ; "#758 ", 758
    ; "https://github.com/loganbnielsen/sol/pull/758", 758
    ];
  List.iter
    (fun input -> check_option_int ("rejects " ^ input) None (parse input))
    [ ""
    ; "  "
    ; "main"
    ; "#"
    ; "BUG-001"
    ; "fix/42"
    ; "42x"
    ; "https://github.com/loganbnielsen/sol/pull/"
    ; "https://github.com/loganbnielsen/sol/pull/abc"
    ]
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
       if [ \"$2\" = checks ]; then printf 'checks\\n' >> calls; cat checks.json; else \
       printf '%s\\n' \"$*\" >> merges; fi\n";
    Unix.chmod "gh" 0o755;
    Unix.putenv "PATH" (dir ^ ":" ^ old_path);
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         let pr : Soldev_merge.pr_info =
           { pr_number = 1
           ; pr_url = "https://example.test/pr/1"
           ; pr_branch = "BUG-001/test"
           ; pr_base_ref = "main"
           ; pr_head_sha = "abc123"
           ; pr_draft = false
           ; pr_cross_repository = false
           }
         in
         let request ~mode pr =
           ignore
             (Soldev_merge.merge_candidates
                ~dry_run:false
                ~mode
                ~targeted:true
                [ Soldev_merge.Ticket_target ("BUG-001", pr) ])
         in
         let clear_merges () = if Sys.file_exists "merges" then Sys.remove "merges" in
         let clear_calls () = if Sys.file_exists "calls" then Sys.remove "calls" in
         List.iter
           (fun json ->
              write_file "checks.json" json;
              request ~mode:Soldev_merge.Immediate pr;
              check_bool "no unsafe immediate merge" false (Sys.file_exists "merges"))
           [ "[]"; {|[{"bucket":"pending"}]|}; {|[{"bucket":"fail"}]|}; "not JSON" ];
         write_file "checks.json" {|[{"bucket":"pass"}]|};
         request ~mode:Soldev_merge.Auto_merge { pr with pr_draft = true };
         check_bool "draft cannot queue auto-merge" false (Sys.file_exists "merges");
         request ~mode:Soldev_merge.Immediate pr;
         check_bool
           "green required CI merges without any review marker"
           true
           (Sys.file_exists "merges");
         clear_merges ();
         write_file "checks.json" {|[{"bucket":"pending"}]|};
         clear_calls ();
         request ~mode:Soldev_merge.Auto_merge pr;
         let command = In_channel.with_open_text "merges" In_channel.input_all in
         check_bool
           "pending CI queues native auto-merge"
           true
           (String.ends_with ~suffix:" --auto\n" command);
         check_bool
           "the ticket path keeps its old gates and consults no checks when queueing"
           false
           (Sys.file_exists "calls")))
;;

let capture_stdout f =
  let path = Filename.temp_file "soldev-capture-" ".txt" in
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved = Unix.dup Unix.stdout in
  Unix.dup2 fd Unix.stdout;
  Unix.close fd;
  let result =
    Fun.protect
      ~finally:(fun () ->
        flush stdout;
        Unix.dup2 saved Unix.stdout;
        Unix.close saved)
      (fun () ->
         let result = f () in
         flush stdout;
         result)
  in
  let text = In_channel.with_open_text path In_channel.input_all in
  Sys.remove path;
  text, result
;;

let containing haystack needle =
  let nlen = String.length needle in
  let found = ref false in
  for i = 0 to String.length haystack - nlen do
    if String.sub haystack i nlen = needle then found := true
  done;
  !found
;;

let pr_json ~draft ~branch =
  Printf.sprintf
    {|[{"number":42,"url":"https://example.test/pull/42","headRefName":"%s",|}
    branch
  ^ Printf.sprintf {|"headRefOid":"sha42","isDraft":%b}]|} draft
;;

let test_pr_target_merge_path () =
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
      "internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-002.md"
      "---\n\
       id: BUG-002\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       A ticket waiting on an unstarted dependency\n\n\
       **Depends on:** BUG-003.\n";
    write_file
      "internal/pipeline/tickets/BACKLOG/BUG-003.md"
      "---\n\
       id: BUG-003\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       Not started\n\n\
       **Depends on:** None.\n";
    write_file
      "gh"
      {|#!/bin/sh
case "$1 $2" in
"pr list") cat prs.json ;;
"pr checks") printf 'checks\n' >> calls; cat checks.json ;;
"pr merge") printf '%s\n' "$*" >> merges ;;
"api repos/"*) if [ -f protection-absent ]; then printf '0'; else printf '1'; fi ;;
*) exit 1 ;;
esac
|};
    Unix.chmod "gh" 0o755;
    Unix.putenv "PATH" (dir ^ ":" ^ old_path);
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         let run ?(mode = Soldev_merge.Auto_merge) target =
           Soldev_merge.run_merge
             ~dry_run:false
             ~mode
             ~ticket_filter:None
             ~pr_target:target
         in
         let run_ticketed target =
           Soldev_merge.run_merge
             ~dry_run:false
             ~mode:Soldev_merge.Auto_merge
             ~ticket_filter:(Some "BUG-001")
             ~pr_target:target
         in
         let merges () =
           if Sys.file_exists "merges"
           then In_channel.with_open_text "merges" In_channel.input_all
           else ""
         in
         let clear_merges () = if Sys.file_exists "merges" then Sys.remove "merges" in
         let message_of = function
           | Ok () -> ""
           | Error { Soldev_exit.message; _ } -> Option.value ~default:"" message
         in
         write_file "checks.json" {|[{"bucket":"pass"}]|};
         write_file "prs.json" (pr_json ~draft:false ~branch:"docs/auto-merge-default");
         run (Some "42") |> ignore;
         check_bool
           "a ticketless PR queues by number with the head pinned"
           true
           (String.ends_with ~suffix:" --auto\n" (merges ())
            && containing (merges ()) "sha42");
         clear_merges ();
         run (Some "#42") |> ignore;
         check_bool "#42 is the same target" true (Sys.file_exists "merges");
         clear_merges ();
         run (Some "https://example.test/pull/42") |> ignore;
         check_bool "a PR URL is the same target" true (Sys.file_exists "merges");
         clear_merges ();
         write_file "prs.json" (pr_json ~draft:false ~branch:"BUG-001/test");
         run (Some "42") |> ignore;
         check_bool
           "a PR whose branch names a DONE ticket still queues"
           true
           (Sys.file_exists "merges");
         check_bool
           "a junk target is refused by name"
           true
           (containing
              (message_of (run (Some "not-a-pr")))
              "is not a pull request number or URL");
         check_bool
           "an unknown PR number is refused by name"
           true
           (containing (message_of (run (Some "99"))) "no open pull request #99");
         check_bool
           "a ticket ID and --pr together are refused by name"
           true
           (containing (message_of (run_ticketed (Some "42"))) "not both");
         clear_merges ();
         write_file "checks.json" {|[{"bucket":"pass"}]|};
         write_file "prs.json" (pr_json ~draft:false ~branch:"BUG-002/blocked");
         let text, _ = capture_stdout (fun () -> run (Some "42")) in
         check_bool
           "an unresolved ticket behind the PR refuses it, naming the reason"
           true
           (containing text "ticket prerequisites unresolved"
            && not (Sys.file_exists "merges"));
         write_file "prs.json" (pr_json ~draft:true ~branch:"docs/auto-merge-default");
         let text, _ = capture_stdout (fun () -> run (Some "42")) in
         check_bool
           "a draft PR is refused, naming the reason"
           true
           (containing text "draft PR" && not (Sys.file_exists "merges"));
         write_file "prs.json" (pr_json ~draft:false ~branch:"docs/auto-merge-default");
         write_file "protection-absent" "";
         let text, _ = capture_stdout (fun () -> run (Some "42")) in
         check_bool
           "a base branch with no required checks is refused, naming the reason"
           true
           (containing text "no required checks configured"
            && not (Sys.file_exists "merges"));
         Sys.remove "protection-absent";
         clear_merges ();
         write_file "checks.json" "not JSON";
         run (Some "42") |> ignore;
         check_bool
           "queueing consults no check rollup, so a PR whose checks have not been \
            reported yet still queues"
           true
           (String.ends_with ~suffix:" --auto\n" (merges ()));
         clear_merges ();
         write_file "checks.json" {|[{"bucket":"pending"}]|};
         let text, _ =
           capture_stdout (fun () -> run ~mode:Soldev_merge.Immediate (Some "42"))
         in
         check_bool
           "--immediate on pending CI is refused, naming the reason"
           true
           (containing text "required checks not green" && not (Sys.file_exists "merges"));
         run (Some "42") |> ignore;
         check_bool
           "the default queues the same pending PR instead of merging it"
           true
           (String.ends_with ~suffix:" --auto\n" (merges ()));
         clear_merges ();
         write_file "checks.json" {|[{"bucket":"pass"}]|};
         run ~mode:Soldev_merge.Immediate (Some "42") |> ignore;
         check_bool
           "--immediate merges green CI without --auto"
           true
           (Sys.file_exists "merges" && not (containing (merges ()) " --auto"))))
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
    | Soldev_merge.Report_success -> "pass"
    | Soldev_merge.Report_perf_regression -> "perf"
    | Soldev_merge.Report_local_failure rc -> Printf.sprintf "report:%d" rc
  in
  Alcotest.(check string)
    "0 is a clean suite"
    "pass"
    (show (Soldev_merge.post_merge_action_of_rc 0));
  Alcotest.(check string)
    "2 is the perf-ratio verdict, informational"
    "perf"
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

let test_merge_finish_does_not_write_a_baseline_commit () =
  in_temp_dir (fun () ->
    git_ok "init -q";
    git_ok "config user.email soldev@test";
    git_ok "config user.name soldev";
    Unix.mkdir "internal" 0o755;
    Unix.mkdir "internal/tooling" 0o755;
    Unix.mkdir "internal/tooling/scripts" 0o755;
    Unix.mkdir "internal/tooling/perf" 0o755;
    let baseline = "internal/tooling/perf/perf_baseline.json" in
    write_file baseline "original\n";
    let runner = "internal/tooling/scripts/run_tests.sh" in
    write_file
      runner
      "#!/bin/sh\n\
       if [ \"$1\" = \"--update-baseline\" ]; then printf 'changed\\n' > \
       internal/tooling/perf/perf_baseline.json; fi\n\
       exit 0\n";
    Unix.chmod runner 0o755;
    git_ok "add .";
    git_ok "commit -qm initial";
    let initial = rev_parse "HEAD" in
    (match Soldev_merge.run_merge_finish ~ticket_id:"BUG-038" ~merge_sha:initial with
     | Ok () -> ()
     | Error _ -> Alcotest.fail "unexpected merge-finish failure");
    check_string "no local commit" initial (rev_parse "HEAD");
    check_string
      "baseline untouched"
      "original\n"
      (In_channel.with_open_bin baseline In_channel.input_all))
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

let test_review_lookup_names_a_merged_pr () =
  let message =
    Soldev_merge.review_lookup_error
      ~ticket_id:"BUG-115"
      ~inventory:(Ok [ repo_pr ~commit:"4e426729" 860 "BUG-115/database-suites-run" ])
  in
  check_bool "names the PR" true (contains ~needle:"#860" message);
  check_bool "says it is merged" true (contains ~needle:"already merged" message);
  check_bool "names the merge commit" true (contains ~needle:"4e426729" message);
  check_bool
    "does not claim no PR exists"
    false
    (contains ~needle:"no open PR found" message)
;;

let test_review_lookup_names_a_closed_pr () =
  let message =
    Soldev_merge.review_lookup_error
      ~ticket_id:"BUG-115"
      ~inventory:(Ok [ repo_pr ~state:"CLOSED" 860 "BUG-115/database-suites-run" ])
  in
  check_bool "names the PR" true (contains ~needle:"#860" message);
  check_bool "says it is closed" true (contains ~needle:"is closed, not open" message);
  check_bool
    "does not claim it was merged"
    false
    (contains ~needle:"already merged" message)
;;

let test_review_lookup_without_any_pr_keeps_the_plain_message () =
  check_string
    "the state it describes"
    "error: no open PR found for BUG-115 (branch prefix BUG-115/)"
    (Soldev_merge.review_lookup_error ~ticket_id:"BUG-115" ~inventory:(Ok []))
;;

let test_review_lookup_reports_a_failed_inventory () =
  let message =
    Soldev_merge.review_lookup_error
      ~ticket_id:"BUG-115"
      ~inventory:(Error "gh pr list --state all exited 1: no such host")
  in
  check_bool "names the failed lookup" true (contains ~needle:"no such host" message);
  check_bool
    "does not claim the PR is merged or absent"
    false
    (contains ~needle:"already merged" message);
  check_bool
    "does not claim no PR exists"
    false
    (contains ~needle:"no open PR found for BUG-115 (branch prefix BUG-115/)" message)
;;

let test_review_lookup_matches_the_ticket_prefix_only () =
  let message =
    Soldev_merge.review_lookup_error
      ~ticket_id:"BUG-115"
      ~inventory:(Ok [ repo_pr ~commit:"abc" 999 "BUG-911/another-ticket" ])
  in
  check_bool
    "another ticket's PR is not this ticket's"
    false
    (contains ~needle:"#999" message)
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
    ; ( "merge outcome"
      , [ Alcotest.test_case
            "a skipped targeted merge is not a success"
            `Quick
            test_a_skipped_targeted_merge_is_not_a_success
        ] )
    ; ( "worktree_porcelain"
      , [ Alcotest.test_case
            "parses paths and branches"
            `Quick
            test_parse_worktree_porcelain
        ] )
    ; ( "merge head pinning"
      , [ Alcotest.test_case
            "prefers the branch ref to the payload's head"
            `Quick
            test_pinned_head_sha_prefers_the_branch_ref
        ; Alcotest.test_case
            "keeps the listed head when it cannot be improved"
            `Quick
            test_pinned_head_sha_keeps_the_listed_sha_when_it_cannot_be_improved
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
        ; Alcotest.test_case
            "merge-finish leaves HEAD and baseline untouched"
            `Quick
            test_merge_finish_does_not_write_a_baseline_commit
        ] )
    ; ( "CI-gated merges"
      , [ Alcotest.test_case
            "required checks are successful and nonempty"
            `Quick
            test_required_checks
        ; Alcotest.test_case "head-pinned native merge commands" `Quick test_merge_command
        ; Alcotest.test_case
            "the default queues auto-merge and --immediate is the opt-in"
            `Quick
            test_default_mode_queues_auto_merge
        ; Alcotest.test_case
            "merge and queue gates without review markers"
            `Quick
            test_merge_without_review_marker
        ] )
    ; ( "review lookup states (INFRA-098)"
      , [ Alcotest.test_case
            "names a merged PR and its commit"
            `Quick
            test_review_lookup_names_a_merged_pr
        ; Alcotest.test_case
            "names a closed PR"
            `Quick
            test_review_lookup_names_a_closed_pr
        ; Alcotest.test_case
            "keeps the plain message when no PR exists"
            `Quick
            test_review_lookup_without_any_pr_keeps_the_plain_message
        ; Alcotest.test_case
            "reports a failed inventory instead of guessing"
            `Quick
            test_review_lookup_reports_a_failed_inventory
        ; Alcotest.test_case
            "matches the ticket's own branch prefix"
            `Quick
            test_review_lookup_matches_the_ticket_prefix_only
        ] )
    ; ( "pull-request merge targets (FEAT-115)"
      , [ Alcotest.test_case
            "parses numbers, #numbers and PR URLs"
            `Quick
            test_parse_pr_number
        ; Alcotest.test_case
            "queues, refuses by name, and matches the ticket path"
            `Quick
            test_pr_target_merge_path
        ] )
    ]
;;
