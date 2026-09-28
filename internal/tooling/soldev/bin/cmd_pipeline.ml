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

let auto_merge_flag =
  Arg.(
    value
    & flag
    & info [ "auto" ] ~doc:"Queue GitHub squash auto-merge after required CI succeeds")
;;

let run_merge dry_run auto_merge ticket_filter =
  Soldev_merge.run_merge ~dry_run ~auto_merge ~ticket_filter |> exit_on
;;

let merge_cmd =
  Cmd.v
    (Cmd.info
       "merge"
       ~doc:
         "Merge non-draft, CI-green PRs; use --auto to wait on GitHub — a ticket lands \
          in DONE because its own branch already committed that move, not because this \
          command moves anything locally. Pass a ticket ID to merge one; omit to sweep \
          all open, ready PRs.")
    Term.(const run_merge $ dry_run_flag $ auto_merge_flag $ merge_ticket_arg)
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

let cmd =
  Cmd.group
    (Cmd.info
       "pipeline"
       ~doc:
         "Deterministic pipeline operations: merge tickets, process review results, list \
          status")
    [ ls_cmd
    ; check_cmd
    ; validate_cmd
    ; submit_cmd
    ; merge_cmd
    ; merge_finish_cmd
    ; review_cmd
    ; check_reverts_cmd
    ]
;;
