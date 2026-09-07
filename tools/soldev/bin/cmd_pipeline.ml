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
         ~doc:"Ticket to merge (e.g. EXP-005). Omit to merge all READY_TO_MERGE tickets.")

let merge_cmd =
  Cmd.v
    (Cmd.info "merge"
       ~doc:"Merge READY_TO_MERGE tickets into main, remove worktrees, move to DONE. \
             Pass a ticket ID to merge one; omit to merge all.")
    Term.(const Soldev_merge.run_merge
          $ dry_run_flag $ accept_performance_regression_flag $ merge_ticket_arg)

let ticket_arg =
  Arg.(required & pos 0 (some string) None &
       info [] ~docv:"TICKET-ID" ~doc:"e.g. EXP-005")

let submit_cmd =
  Cmd.v
    (Cmd.info "submit"
       ~doc:"Push an IN_PROGRESS ticket's branch, open a PR (or reuse an \
             existing one for that branch), record it in the ticket's \
             frontmatter, and move the ticket to REVIEW.")
    Term.(const Soldev_merge.run_submit $ ticket_arg)

let result_file_arg =
  Arg.(value & opt (some string) None &
       info ["result-file"; "f"] ~docv:"PATH"
         ~doc:"JSON review result file (default: read stdin)")

let review_cmd =
  Cmd.v
    (Cmd.info "review"
       ~doc:"Process a structured JSON review result, moving the ticket to \
             READY_TO_MERGE or READY_FOR_ENGINEERING")
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

let cmd =
  Cmd.group
    (Cmd.info "pipeline"
       ~doc:"Deterministic pipeline operations: merge tickets, process review results, list status")
    [ ls_cmd; check_cmd; submit_cmd; merge_cmd; review_cmd ]
