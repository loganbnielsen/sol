open Cmdliner

let dry_run_flag =
  Arg.(
    value
    & flag
    & info [ "dry-run" ] ~doc:"Print what would happen without making changes")
;;

let merge_ticket_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info
        []
        ~docv:"TICKET-ID"
        ~doc:
          "Ticket to merge (e.g. EXP-005) — looked up by its open PR, not a local \
           directory. Omit to sweep every open PR whose branch looks like \
           <TICKET-ID>/....")
;;

let exit_on = Soldev_exit.exit_on

let immediate_flag =
  Arg.(
    value
    & flag
    & info
        [ "immediate" ]
        ~doc:
          "Merge now instead of queueing auto-merge; allowed only when the required \
           checks are already green")
;;

let pr_target_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "pr" ]
        ~docv:"PR"
        ~doc:
          "Target this pull request instead of a ticket: a number (758), #758, or a PR \
           URL. Mutually exclusive with the TICKET-ID positional.")
;;

let run_merge dry_run immediate pr_target ticket_filter =
  Soldev_merge.run_merge
    ~dry_run
    ~mode:(Soldev_merge.merge_mode_of_flag ~immediate)
    ~ticket_filter
    ~pr_target
  |> exit_on
;;

let merge_cmd =
  Cmd.v
    (Cmd.info
       "merge"
       ~doc:
         "Merge a non-draft PR whose prerequisites are resolved, by queueing native \
          squash auto-merge — the default — so GitHub lands it the moment required \
          checks pass. --immediate merges now instead, and only when required checks are \
          already green. A ticket lands in DONE because its own branch already committed \
          that move, not because this command moves anything locally. Pass a ticket ID \
          to merge one, --pr to target a pull request that names no ticket, or omit both \
          to sweep all open, ready PRs.")
    Term.(
      const run_merge $ dry_run_flag $ immediate_flag $ pr_target_arg $ merge_ticket_arg)
;;

let ticket_arg =
  Arg.(
    required & pos 0 (some string) None & info [] ~docv:"TICKET-ID" ~doc:"e.g. EXP-005")
;;

let merge_sha_arg =
  Arg.(
    required
    & pos 1 (some string) None
    & info
        []
        ~docv:"MERGE-SHA"
        ~doc:"The merged commit being measured in this owned checkout")
;;

let run_merge_finish ticket_id merge_sha =
  Soldev_merge.run_merge_finish ~ticket_id ~merge_sha |> exit_on
;;

let merge_finish_cmd =
  Cmd.v
    (Cmd.info
       "merge-finish"
       ~doc:
         "Optional post-merge maintenance in an owned checkout: run tests and record the \
          perf baseline. Does not gate merges or revert failures. Not invoked \
          automatically by merge.")
    Term.(const run_merge_finish $ ticket_arg $ merge_sha_arg)
;;

let submit_cmd =
  Cmd.v
    (Cmd.info
       "submit"
       ~doc:
         "Run from inside the ticket's worktree, after your final commit has already \
          moved the ticket file to DONE/ on that branch. Pushes the branch and opens a \
          PR (or reuses an existing one) — never touches internal/pipeline/tickets/ on \
          main.")
    Term.(const (fun id -> Soldev_merge.run_submit id |> exit_on) $ ticket_arg)
;;

let result_file_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "result-file"; "f" ]
        ~docv:"PATH"
        ~doc:"JSON review result file (default: read stdin)")
;;

let review_cmd =
  Cmd.v
    (Cmd.info
       "review"
       ~doc:
         "Process a structured JSON review result by leaving it as a PR comment — marked \
          SOLDEV-REVIEW: PASS on pass (informational, not a merge prerequisite), an \
          ordinary violations comment on fail. Not a formal GitHub review: `gh` always \
          runs as the PR's own author here, and GitHub refuses self-approval. No ticket \
          file moves.")
    Term.(
      const (fun id file -> Soldev_merge.run_review id file |> exit_on)
      $ ticket_arg
      $ result_file_arg)
;;

let include_done_flag =
  Arg.(value & flag & info [ "all"; "a" ] ~doc:"Include DONE tickets in the listing")
;;

let ls_cmd =
  Cmd.v
    (Cmd.info
       "ls"
       ~doc:"List tickets grouped by pipeline stage. Pass --all to include DONE.")
    Term.(const (fun all -> Soldev_merge.run_ls all |> exit_on) $ include_done_flag)
;;

let check_cmd =
  Cmd.v
    (Cmd.info
       "check"
       ~doc:
         "Check whether a ticket is actionable, including human-decision gates and \
          dependency status.")
    Term.(const (fun id -> Soldev_merge.run_check id |> exit_on) $ ticket_arg)
;;

let validate_cmd =
  Cmd.v
    (Cmd.info
       "validate"
       ~doc:
         "Validate every ticket in the pipeline tree — BACKLOG, READY_FOR_ENGINEERING \
          and DONE — with the parser the other commands read tickets with. An unreadable \
          ticket (no frontmatter block, invalid YAML, or a missing \
          id/type/severity/source) is an error naming the file, never an omitted or \
          empty-columned ticket; exits 1 if any is unreadable. CI runs this over the \
          complete tree.")
    Term.(const (fun () -> Soldev_merge.run_validate () |> exit_on) $ const ())
;;

let check_reverts_cmd =
  Cmd.v
    (Cmd.info
       "check-reverts"
       ~doc:
         "Scan git history for a merge that was later reverted whose ticket still sits \
          in DONE/ — catches a fix that broke, got reverted, and was never refixed. \
          Exits 1 if any are found.")
    Term.(const (fun () -> Soldev_merge.run_check_reverts () |> exit_on) $ const ())
;;

let cleanup_cmd =
  let pr = Arg.(required & pos 0 (some int) None & info [] ~docv:"PR") in
  let worktree = Arg.(required & pos 1 (some string) None & info [] ~docv:"WORKTREE") in
  let apply =
    Arg.(
      value
      & flag
      & info
          [ "apply" ]
          ~doc:"Remove this owned, idle worktree and its branch after verification")
  in
  Cmd.v
    (Cmd.info "cleanup" ~doc:"Preview cleanup of an owned, idle worktree for a merged PR")
    Term.(
      const (fun apply pr worktree -> Soldev_cleanup.run ~apply ~pr ~worktree |> exit_on)
      $ apply
      $ pr
      $ worktree)
;;

let cmd =
  Cmd.group
    (Cmd.info
       "pipeline"
       ~doc:
         "Deterministic pipeline operations: merge tickets, process review results, list \
          status")
    [ cleanup_cmd
    ; ls_cmd
    ; check_cmd
    ; validate_cmd
    ; submit_cmd
    ; merge_cmd
    ; merge_finish_cmd
    ; review_cmd
    ; check_reverts_cmd
    ]
;;
