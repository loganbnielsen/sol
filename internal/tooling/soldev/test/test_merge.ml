let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let check_option_string msg expected actual =
  Windtrap.equal (Windtrap.option Windtrap.string) ~msg expected actual
;;

let check_option_int msg expected actual =
  Windtrap.equal (Windtrap.option Windtrap.int) ~msg expected actual
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
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string (Windtrap.option Windtrap.string)))
    ~msg:"parses worktree paths and branches"
    expected
    (Soldev_merge.parse_worktree_porcelain lines)
;;

let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

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

let git args = Sys.command (Printf.sprintf "git %s >/dev/null 2>&1" args) = 0
let git_ok args = check_bool (Printf.sprintf "git %s succeeds" args) true (git args)

let rev_parse ref =
  let ic = Unix.open_process_in (Printf.sprintf "git rev-parse %s 2>/dev/null" ref) in
  let line = In_channel.input_line ic |> Option.value ~default:"" in
  ignore (Unix.close_process_in ic);
  String.trim line
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
    git_ok "init -q";
    git_ok "config user.email soldev@test";
    git_ok "config user.name soldev";
    write_file ".gitkeep" "";
    git_ok "add .gitkeep";
    git_ok "commit -qm base";
    git_ok "update-ref refs/remotes/origin/main HEAD";
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
    git_ok "init -q";
    git_ok "config user.email soldev@test";
    git_ok "config user.name soldev";
    git_ok "add internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-002.md";
    git_ok "add internal/pipeline/tickets/BACKLOG/BUG-003.md";
    git_ok "commit -qm base";
    git_ok "update-ref refs/remotes/origin/main HEAD";
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

let test_merge_refusal_ticket_gate () =
  let decide ticket_gate =
    Soldev_merge.merge_refusal
      ~mode:Soldev_merge.Auto_merge
      ~ticket_gate
      ~pr_draft:false
      ~checks:Soldev_merge.Checks_not_consulted
      ~checks_configured:Soldev_merge.Configuration_not_consulted
    |> Option.map (function
      | Soldev_merge.Ticket_prerequisites_unresolved -> "unresolved"
      | Soldev_merge.Refused_ticket_state_unreadable -> "unreadable"
      | Soldev_merge.Refused_draft -> "draft"
      | Soldev_merge.Refused_no_required_checks -> "no-checks"
      | Soldev_merge.Refused_checks_unreadable -> "checks-unreadable"
      | Soldev_merge.Refused_checks_not_green -> "not-green")
  in
  check_option_string
    "an unreadable base refuses instead of guessing"
    (Some "unreadable")
    (decide Soldev_merge.Ticket_gate_unreadable);
  check_option_string
    "an unresolved prerequisite refuses"
    (Some "unresolved")
    (decide Soldev_merge.Ticket_gate_prerequisites_unresolved);
  check_option_string
    "a filing, or a resolved implementation, is not gated"
    None
    (decide Soldev_merge.Ticket_gate_open)
;;

let test_filing_pr_skips_the_prerequisite_gate () =
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
      "internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-101.md"
      "---\n\
       id: BUG-101\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       An implementation whose dependency is not done\n\n\
       **Depends on:** BUG-102.\n";
    write_file
      "internal/pipeline/tickets/BACKLOG/BUG-102.md"
      "---\n\
       id: BUG-102\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       Not started\n\n\
       **Depends on:** None.\n";
    git_ok "init -q";
    git_ok "config user.email soldev@test";
    git_ok "config user.name soldev";
    git_ok "add internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-101.md";
    git_ok "add internal/pipeline/tickets/BACKLOG/BUG-102.md";
    git_ok "commit -qm base";
    git_ok "update-ref refs/remotes/origin/main HEAD";
    write_file
      "internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-103.md"
      "---\n\
       id: BUG-103\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       A filing whose dependency is not done\n\n\
       **Depends on:** BUG-102.\n";
    write_file
      "gh"
      {|#!/bin/sh
case "$1 $2" in
"pr list") cat prs.json ;;
"pr checks") cat checks.json ;;
"pr merge") printf '%s\n' "$*" >> merges ;;
"api repos/"*) printf '1' ;;
*) exit 1 ;;
esac
|};
    Unix.chmod "gh" 0o755;
    Unix.putenv "PATH" (dir ^ ":" ^ old_path);
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         let run branch =
           write_file "prs.json" (pr_json ~draft:false ~branch);
           Soldev_merge.run_merge
             ~dry_run:false
             ~mode:Soldev_merge.Auto_merge
             ~ticket_filter:None
             ~pr_target:(Some "42")
         in
         let merges () =
           if Sys.file_exists "merges"
           then In_channel.with_open_text "merges" In_channel.input_all
           else ""
         in
         write_file "checks.json" {|[{"bucket":"pass"}]|};
         let _, filing = capture_stdout (fun () -> run "BUG-103/filing") in
         check_bool
           "a filing PR whose new ticket declares an unresolved dependency still queues"
           true
           (filing = Ok () && containing (merges ()) "--auto");
         if Sys.file_exists "merges" then Sys.remove "merges";
         let text, implementation = capture_stdout (fun () -> run "BUG-101/impl") in
         check_bool
           "an implementation whose dependency is unresolved is still refused"
           true
           (containing text "ticket prerequisites unresolved"
            && (match implementation with
                | Error _ -> true
                | Ok () -> false)
            && not (Sys.file_exists "merges"))))
;;

let test_submit_accepts_a_filing_and_a_done_move () =
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
      "internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-201.md"
      "---\n\
       id: BUG-201\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       A filing that depends on unstarted work\n\n\
       **Depends on:** BUG-202.\n";
    write_file
      "internal/pipeline/tickets/BACKLOG/BUG-202.md"
      "---\n\
       id: BUG-202\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       Not started\n\n\
       **Depends on:** None.\n";
    git_ok "init -q";
    git_ok "config user.email soldev@test";
    git_ok "config user.name soldev";
    git_ok "add internal/pipeline/tickets/BACKLOG/BUG-202.md";
    git_ok "commit -qm base";
    git_ok "update-ref refs/remotes/origin/main HEAD";
    git_ok "checkout -q -b BUG-201/filing";
    git_ok "add internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-201.md";
    git_ok "commit -qm file";
    git_ok "init -q --bare origin.git";
    git_ok "remote add origin origin.git";
    write_file
      "gh"
      "#!/bin/sh\n\
       case \"$1 $2\" in\n\
       \"pr list\") printf '[]' ;;\n\
       \"pr create\") printf 'https://example.test/pull/9\\n' ;;\n\
       *) exit 1 ;;\n\
       esac\n";
    Unix.chmod "gh" 0o755;
    Unix.putenv "PATH" (dir ^ ":" ^ old_path);
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         check_bool
           "a ticket newly added by this branch submits without a DONE move"
           true
           (Soldev_merge.run_submit "BUG-201" = Ok ());
         git_ok
           "mv internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-201.md \
            internal/pipeline/tickets/DONE/BUG-201.md";
         git_ok "add -A internal/pipeline/tickets";
         git_ok "commit -qm done";
         check_bool
           "an implementation that moves the ticket to DONE still submits"
           true
           (Soldev_merge.run_submit "BUG-201" = Ok ())))
;;

let test_submit_refuses_a_base_ready_ticket_left_in_ready () =
  in_temp_dir (fun () ->
    Unix.mkdir "internal" 0o755;
    Unix.mkdir "internal/pipeline" 0o755;
    Unix.mkdir "internal/pipeline/tickets" 0o755;
    List.iter
      (fun state -> Unix.mkdir ("internal/pipeline/tickets/" ^ state) 0o755)
      [ "BACKLOG"; "READY_FOR_ENGINEERING"; "DONE" ];
    write_file
      "internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-301.md"
      "---\n\
       id: BUG-301\n\
       type: bug\n\
       severity: low\n\
       source: test\n\
       ---\n\n\
       An implementation left in READY\n\n\
       **Depends on:** None.\n";
    git_ok "init -q";
    git_ok "config user.email soldev@test";
    git_ok "config user.name soldev";
    git_ok "add internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-301.md";
    git_ok "commit -qm base";
    git_ok "update-ref refs/remotes/origin/main HEAD";
    git_ok "checkout -q -b BUG-301/impl";
    check_bool
      "a ticket READY at the base must be carried to DONE before submitting"
      true
      (match Soldev_merge.run_submit "BUG-301" with
       | Error { Soldev_exit.message = Some message; _ } ->
         containing message "move it to DONE"
       | Error { Soldev_exit.message = None; _ } -> false
       | Ok () -> false))
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

let unpushed_of branch =
  match Soldev_merge.worktree_snapshot_of_entry (Sys.getcwd (), Some branch) with
  | Some (snapshot : Soldev_merge.worktree_snapshot) -> snapshot.ws_unpushed
  | None -> Windtrap.fail "expected a worktree snapshot"
;;

let check_unpushed msg expected branch =
  Windtrap.equal (Windtrap.option Windtrap.bool) ~msg expected (unpushed_of branch)
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
    check_unpushed "at origin/main is not unpushed" (Some false) "work";
    write_file "f.txt" "b\n";
    git_ok "add f.txt";
    git_ok "commit -qm b";
    let b = rev_parse "HEAD" in
    check_unpushed "ahead of origin/main is unpushed" (Some true) "work";
    git_ok (Printf.sprintf "update-ref refs/remotes/origin/main %s" b);
    git_ok (Printf.sprintf "checkout -q -B work %s" a);
    check_unpushed "behind origin/main is not unpushed" (Some false) "work";
    git_ok (Printf.sprintf "update-ref refs/remotes/origin/work %s" a);
    check_unpushed "equal to its upstream is not unpushed" (Some false) "work";
    git_ok (Printf.sprintf "checkout -q -B work %s" b);
    check_unpushed "ahead of its upstream is unpushed" (Some true) "work";
    git_ok (Printf.sprintf "update-ref refs/remotes/origin/work %s" b);
    git_ok (Printf.sprintf "checkout -q -B work %s" a);
    check_unpushed "behind its upstream is not unpushed" (Some false) "work";
    git_ok "update-ref -d refs/remotes/origin/main";
    git_ok "update-ref -d refs/remotes/origin/work";
    check_unpushed "an unresolvable ref is unreadable, not silently clean" None "work")
;;

let test_unreadable_git_state_is_annotated () =
  in_temp_dir (fun () ->
    let old_path = Sys.getenv "PATH" in
    let dir = Sys.getcwd () in
    let fake_git = Filename.concat dir "git" in
    write_file fake_git "#!/bin/sh\nexit 9\n";
    Unix.chmod fake_git 0o755;
    Unix.putenv "PATH" (dir ^ ":" ^ old_path);
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         match Soldev_merge.worktree_annotation_for_ticket "CODE_LAYER-030" with
         | Some annotation ->
           check_bool
             "names the unreadable worktree state"
             true
             (contains ~needle:"unreadable" annotation)
         | None ->
           Windtrap.fail
             "a failed git worktree list must annotate, not read as no worktree"))
;;

let test_unreadable_status_is_not_reported_clean () =
  in_temp_dir (fun () ->
    match Soldev_merge.worktree_snapshot_of_entry (Sys.getcwd (), Some "work") with
    | Some (snapshot : Soldev_merge.worktree_snapshot) ->
      check_bool
        "dirty state is unreadable, not clean"
        true
        (Option.is_none snapshot.ws_dirty)
    | None -> Windtrap.fail "expected a worktree snapshot")
;;

let with_failing_git script f =
  let old_path = Sys.getenv "PATH" in
  let dir = Sys.getcwd () in
  let fake_git = Filename.concat dir "git" in
  write_file fake_git script;
  Unix.chmod fake_git 0o755;
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" old_path) f
;;

let test_current_branch_names_a_failed_read () =
  in_temp_dir (fun () ->
    with_failing_git
      "#!/bin/sh\nprintf 'fatal: not a git repository\\n' >&2\nexit 128\n"
      (fun () ->
         match Soldev_merge.current_branch () with
         | Ok branch ->
           Windtrap.fail ("a failed read must not become a branch name: " ^ branch)
         | Error { Soldev_exit.message = Some message; _ } ->
           check_bool
             "names the read failure"
             true
             (contains ~needle:"could not be read" message
              && contains ~needle:"not a git repository" message)
         | Error { Soldev_exit.message = None; _ } ->
           Windtrap.fail "the refusal must carry the reason"))
;;

let test_check_reverts_reports_an_unreadable_log () =
  in_temp_dir (fun () ->
    with_failing_git "#!/bin/sh\nexit 9\n" (fun () ->
      match Soldev_merge.run_check_reverts () with
      | Ok () -> Windtrap.fail "a git log that could not be read must not read as clean"
      | Error { Soldev_exit.message = Some message; _ } ->
        check_bool
          "names the read failure"
          true
          (contains ~needle:"could not be read" message)
      | Error { Soldev_exit.message = None; _ } ->
        Windtrap.fail "the refusal must carry the reason"))
;;

let test_run_cmd_checked_carries_the_reason () =
  match Soldev_shell.run_cmd_checked "echo out; echo err >&2; exit 3" with
  | Ok _ -> Windtrap.fail "a failing command must not read as Ok"
  | Error r ->
    check_bool
      "names the exit code and stderr"
      true
      (contains ~needle:"exited with code 3: err" (Sol_process.failure_message r))
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
  Windtrap.run
    "soldev_merge"
    [ Windtrap.group
        "extract_reverted_branch"
        [ Windtrap.test "matches revert-merge subject" test_extract_reverted_branch_match
        ; Windtrap.test "ignores unrelated subject" test_extract_reverted_branch_no_match
        ]
    ; Windtrap.group
        "ticket_id_from_branch"
        [ Windtrap.test "strips slash suffix" test_ticket_id_from_branch_with_slash
        ; Windtrap.test "passes through when no slash" test_ticket_id_from_branch_no_slash
        ]
    ; Windtrap.group
        "merge outcome"
        [ Windtrap.test
            "a skipped targeted merge is not a success"
            test_a_skipped_targeted_merge_is_not_a_success
        ]
    ; Windtrap.group
        "worktree_porcelain"
        [ Windtrap.test "parses paths and branches" test_parse_worktree_porcelain ]
    ; Windtrap.group
        "merge head pinning"
        [ Windtrap.test
            "prefers the branch ref to the payload's head"
            test_pinned_head_sha_prefers_the_branch_ref
        ; Windtrap.test
            "keeps the listed head when it cannot be improved"
            test_pinned_head_sha_keeps_the_listed_sha_when_it_cannot_be_improved
        ]
    ; Windtrap.group
        "worktree unpushed annotation (BUG-063)"
        [ Windtrap.test "asks git for commits, not shas" test_unpushed_annotation_asks_git
        ]
    ; Windtrap.group
        "worktree read failure (CODE_LAYER-030)"
        [ Windtrap.test
            "an unreadable git worktree list is annotated, not read as absent"
            test_unreadable_git_state_is_annotated
        ; Windtrap.test
            "an unreadable git status is not reported clean"
            test_unreadable_status_is_not_reported_clean
        ]
    ; Windtrap.group
        "git read failures carry the reason (CODE_LAYER-032)"
        [ Windtrap.test
            "the current branch names a failed read"
            test_current_branch_names_a_failed_read
        ; Windtrap.test
            "check-reverts refuses to report a log it could not read"
            test_check_reverts_reports_an_unreadable_log
        ; Windtrap.test
            "a checked run carries the exit code and stderr"
            test_run_cmd_checked_carries_the_reason
        ]
    ; Windtrap.group
        "mentions_id"
        [ Windtrap.test "exact token match" test_mentions_id_exact
        ; Windtrap.test "no match" test_mentions_id_no_match
        ; Windtrap.test
            "rejects prefix embedding"
            test_mentions_id_rejects_prefix_embedding
        ; Windtrap.test "rejects numeric suffix" test_mentions_id_rejects_numeric_suffix
        ]
    ; Windtrap.group
        "stale-binary post-merge race"
        [ Windtrap.test
            "rebuild before invoking avoids the stale-path race"
            test_stale_binary_fails_after_rename
        ]
    ; Windtrap.group
        "CI-gated merges"
        [ Windtrap.test "required checks are successful and nonempty" test_required_checks
        ; Windtrap.test "head-pinned native merge commands" test_merge_command
        ; Windtrap.test
            "the default queues auto-merge and --immediate is the opt-in"
            test_default_mode_queues_auto_merge
        ; Windtrap.test
            "merge and queue gates without review markers"
            test_merge_without_review_marker
        ]
    ; Windtrap.group
        "review lookup states (INFRA-098)"
        [ Windtrap.test
            "names a merged PR and its commit"
            test_review_lookup_names_a_merged_pr
        ; Windtrap.test "names a closed PR" test_review_lookup_names_a_closed_pr
        ; Windtrap.test
            "keeps the plain message when no PR exists"
            test_review_lookup_without_any_pr_keeps_the_plain_message
        ; Windtrap.test
            "reports a failed inventory instead of guessing"
            test_review_lookup_reports_a_failed_inventory
        ; Windtrap.test
            "matches the ticket's own branch prefix"
            test_review_lookup_matches_the_ticket_prefix_only
        ]
    ; Windtrap.group
        "pull-request merge targets (FEAT-115)"
        [ Windtrap.test "parses numbers, #numbers and PR URLs" test_parse_pr_number
        ; Windtrap.test
            "queues, refuses by name, and matches the ticket path"
            test_pr_target_merge_path
        ]
    ; Windtrap.group
        "filing PRs vs implementations (BUG-128)"
        [ Windtrap.test
            "the ticket gate is open to filings and closed to unresolved implementations"
            test_merge_refusal_ticket_gate
        ; Windtrap.test
            "a filing with a dependency queues while an implementation with one is \
             refused"
            test_filing_pr_skips_the_prerequisite_gate
        ; Windtrap.test
            "submit accepts a filing and a DONE move"
            test_submit_accepts_a_filing_and_a_done_move
        ; Windtrap.test
            "submit refuses a base-READY ticket left in READY"
            test_submit_refuses_a_base_ready_ticket_left_in_ready
        ]
    ]
;;
