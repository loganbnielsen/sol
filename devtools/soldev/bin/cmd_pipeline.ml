open Cmdliner

let dry_run_flag =
  Arg.(value & flag & info ["dry-run"]
    ~doc:"Print what would happen without making changes")

let accept_performance_regression_flag =
  Arg.(value & flag & info ["accept-performance-regression"]
    ~doc:"Explicitly accept a detected performance regression, keep the merge, \
          and record a new performance baseline. Functional test failures still \
          block the merge.")

let merge_ticket_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"TICKET-ID"
         ~doc:"Ticket to merge (e.g. EXP-005) — looked up by its open PR, not a \
               local directory. Omit to sweep every open PR whose branch looks \
               like <TICKET-ID>/....")

let run_merge dry_run accept_performance_regression ticket_filter =
  Soldev_merge.run_merge ~dry_run ~accept_performance_regression ~ticket_filter

let merge_cmd =
  Cmd.v
    (Cmd.info "merge"
       ~doc:"Merge approved, CI-green PRs — a ticket lands in DONE because its \
             own branch already committed that move, not because this command \
             moves anything locally. Pass a ticket ID to merge one; omit to \
             sweep all open, ready PRs.")
    Term.(const run_merge
          $ dry_run_flag $ accept_performance_regression_flag $ merge_ticket_arg)

let ticket_arg =
  Arg.(required & pos 0 (some string) None &
       info [] ~docv:"TICKET-ID" ~doc:"e.g. EXP-005")

let merge_sha_arg =
  Arg.(required & pos 1 (some string) None &
       info [] ~docv:"MERGE-SHA" ~doc:"The commit `merge` just synced to local main")

let run_merge_finish ticket_id merge_sha accept_performance_regression =
  Soldev_merge.run_merge_finish
    ~ticket_id ~merge_sha ~accept_performance_regression

let merge_finish_cmd =
  Cmd.v
    (Cmd.info "merge-finish"
       ~doc:"Internal — spawned by `merge` as a subprocess of a binary rebuilt \
             after the PR's merge commit landed, never invoke directly. Runs the \
             post-merge test suite and updates the perf baseline; reverts the \
             merge (ticket and code together) on a real regression.")
    Term.(const run_merge_finish
          $ ticket_arg $ merge_sha_arg $ accept_performance_regression_flag)

let submit_cmd =
  Cmd.v
    (Cmd.info "submit"
       ~doc:"Run from inside the ticket's worktree, after your final commit has \
             already moved the ticket file to DONE/ on that branch. Pushes the \
             branch and opens a PR (or reuses an existing one) — never touches \
             pipeline/tickets/ on main.")
    Term.(const Soldev_merge.run_submit $ ticket_arg)

let result_file_arg =
  Arg.(value & opt (some string) None &
       info ["result-file"; "f"] ~docv:"PATH"
         ~doc:"JSON review result file (default: read stdin)")

let review_cmd =
  Cmd.v
    (Cmd.info "review"
       ~doc:"Process a structured JSON review result by leaving it as a PR \
             comment — marked SOLDEV-REVIEW: PASS on pass (which `merge` \
             checks for), an ordinary violations comment on fail. Not a \
             formal GitHub review: `gh` always runs as the PR's own author \
             here, and GitHub refuses self-approval. No ticket file moves.")
    Term.(const Soldev_merge.run_review $ ticket_arg $ result_file_arg)

let include_done_flag =
  Arg.(value & flag & info ["all"; "a"]
    ~doc:"Include DONE tickets in the listing")

let ls_cmd =
  Cmd.v
    (Cmd.info "ls"
       ~doc:"List tickets grouped by pipeline stage. Pass --all to include DONE.")
    Term.(const Soldev_merge.run_ls $ include_done_flag)

let check_cmd =
  Cmd.v
    (Cmd.info "check"
       ~doc:"Check whether a ticket is actionable, including human-decision \
             gates and dependency status.")
    Term.(const Soldev_merge.run_check $ ticket_arg)

let check_reverts_cmd =
  Cmd.v
    (Cmd.info "check-reverts"
       ~doc:"Scan git history for a merge that was later reverted whose ticket \
             still sits in DONE/ — catches a fix that broke, got reverted, and \
             was never refixed. Exits 1 if any are found.")
    Term.(const Soldev_merge.run_check_reverts $ const ())

let cmd =
  Cmd.group
    (Cmd.info "pipeline"
       ~doc:"Deterministic pipeline operations: merge tickets, process review results, list status")
    [ ls_cmd; check_cmd; submit_cmd; merge_cmd; merge_finish_cmd; review_cmd; check_reverts_cmd ]
