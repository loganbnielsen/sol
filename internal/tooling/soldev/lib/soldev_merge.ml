let read_file = Soldev_shell.read_file
let dir state = Soldev_ticket.state_to_dir state
let ticket_dir state = Filename.concat "internal/pipeline/tickets" (dir state)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let current_branch () =
  Sol_process.output_shell ~echo:false "git rev-parse --abbrev-ref HEAD 2>/dev/null"
;;

let git_branch_exists branch =
  Sol_process.run_shell_rc
    ~echo:false
    (Printf.sprintf "git rev-parse --verify %s >/dev/null 2>&1" (Filename.quote branch))
  = 0
;;

type pr_info =
  { pr_number : int
  ; pr_url : string
  ; pr_branch : string
  ; pr_head_sha : string
  ; pr_draft : bool
  }

let ticket_id_of_branch branch =
  match String.index_opt branch '/' with
  | Some i -> String.sub branch 0 i
  | None -> branch
;;

let pr_of_json j =
  let open Yojson.Basic.Util in
  { pr_number = j |> member "number" |> to_int
  ; pr_url = j |> member "url" |> to_string
  ; pr_branch = j |> member "headRefName" |> to_string
  ; pr_head_sha = j |> member "headRefOid" |> to_string
  ; pr_draft = j |> member "isDraft" |> to_bool
  }
;;

let open_prs () =
  let result =
    Sol_process.run_argv
      [ "gh"
      ; "pr"
      ; "list"
      ; "--state"
      ; "open"
      ; "--json"
      ; "number,url,headRefName,headRefOid,isDraft"
      ; "--limit"
      ; "200"
      ]
  in
  if not (Sol_process.succeeded result)
  then
    Soldev_exit.error
      (Printf.sprintf
         "could not read the open PR inventory from gh (exit %d): %s"
         (Sol_process.exit_code result)
         (String.trim (result.stderr ^ " " ^ result.stdout)))
  else (
    match Yojson.Basic.from_string result.stdout with
    | exception Yojson.Json_error message ->
      Soldev_exit.error ("could not decode the open PR inventory from gh: " ^ message)
    | json ->
      (try Ok (json |> Yojson.Basic.Util.to_list |> List.map pr_of_json) with
       | Yojson.Basic.Util.Type_error (message, _) ->
         Soldev_exit.error ("unexpected gh pr list shape: " ^ message)))
;;

let find_pr_in prs ticket_id =
  List.find_opt (fun p -> ticket_id_of_branch p.pr_branch = ticket_id) prs
;;

let checks_green_of_json = function
  | `List (_ :: _ as checks) ->
    List.for_all
      (function
        | `Assoc fields -> List.assoc_opt "bucket" fields = Some (`String "pass")
        | _ -> false)
      checks
  | _ -> false
;;

let pr_checks_green pr_url =
  let result =
    Sol_process.run_argv
      [ "gh"; "pr"; "checks"; pr_url; "--required"; "--json"; "bucket" ]
  in
  Sol_process.succeeded result
  &&
  try checks_green_of_json (Yojson.Basic.from_string result.stdout) with
  | Yojson.Json_error _ -> false
;;

let review_pass_marker = "SOLDEV-REVIEW: PASS"
let review_fail_marker = "SOLDEV-REVIEW: FAIL"

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix
;;

let merge_command ~auto_merge pr =
  Printf.sprintf
    "gh pr merge %s --squash --match-head-commit %s%s"
    (Filename.quote pr.pr_url)
    (Filename.quote pr.pr_head_sha)
    (if auto_merge then " --auto" else "")
;;

let ticket_id_from_branch branch = ticket_id_of_branch branch

let extract_reverted_branch subject =
  let marker = "Revert \"Merge branch '" in
  let mlen = String.length marker in
  let slen = String.length subject in
  if slen >= mlen && String.sub subject 0 mlen = marker
  then (
    match String.index_from_opt subject mlen '\'' with
    | Some close -> Some (String.sub subject mlen (close - mlen))
    | None -> None)
  else None
;;

let is_id_char c =
  (c >= 'A' && c <= 'Z')
  || (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || c = '_'
  || c = '-'
;;

let mentions_id ~id line =
  let idlen = String.length id
  and linelen = String.length line in
  let rec go p =
    if p + idlen > linelen
    then false
    else if
      String.sub line p idlen = id
      && (p = 0 || not (is_id_char line.[p - 1]))
      && (p + idlen = linelen || not (is_id_char line.[p + idlen]))
    then true
    else go (p + 1)
  in
  go 0
;;

let refixed_after ~id ~revert_hash =
  Soldev_shell.run_cmd_lines
    (Printf.sprintf "git log --oneline %s" (Filename.quote (revert_hash ^ "..HEAD")))
  |> List.exists (mentions_id ~id)
;;

let run_check_reverts () =
  let lines =
    Soldev_shell.run_cmd_lines
      (Printf.sprintf
         "git log --oneline -E --grep=%s"
         (Filename.quote "^Revert \"Merge branch"))
  in
  let flagged =
    lines
    |> List.filter_map (fun line ->
      match String.index_opt line ' ' with
      | None -> None
      | Some i ->
        let hash = String.sub line 0 i in
        let subject = String.sub line (i + 1) (String.length line - i - 1) in
        (match extract_reverted_branch subject with
         | None -> None
         | Some branch ->
           let id = ticket_id_from_branch branch in
           let done_path = Filename.concat (ticket_dir Soldev_ticket.Done) (id ^ ".md") in
           if Sys.file_exists done_path && not (refixed_after ~id ~revert_hash:hash)
           then Some (id, hash, done_path)
           else None))
  in
  if flagged = []
  then (
    Printf.printf "check-reverts: clean — no DONE ticket has a matching revert commit.\n";
    Ok ())
  else (
    Printf.printf
      "check-reverts: %d ticket(s) marked DONE have a merge that was later reverted:\n"
      (List.length flagged);
    List.iter
      (fun (id, hash, path) ->
         Printf.printf
           "  %-12s  revert %s  still in %s — verify the fix is actually live in main, \
            or move it back to READY_FOR_ENGINEERING\n"
           id
           hash
           path)
      flagged;
    Soldev_exit.reported ())
;;

let run_submit ticket_id =
  let open Result.Syntax in
  let done_path = Printf.sprintf "%s/%s.md" (ticket_dir Soldev_ticket.Done) ticket_id in
  let* () =
    if Sys.file_exists done_path
    then Ok ()
    else
      Soldev_exit.error
        (Printf.sprintf
           "error: %s not found. Run this from the ticket's worktree, after your final \
            commit has already moved the ticket file to DONE/ on this branch."
           done_path)
  in
  let branch = current_branch () in
  let* () =
    if branch = "main" || branch = ""
    then
      Soldev_exit.error
        (Printf.sprintf "error: not on a ticket branch (currently on %s)" branch)
    else Ok ()
  in
  Printf.printf "[%s] pushing %s...\n%!" ticket_id branch;
  let* () =
    if
      Soldev_shell.run_cmd
        (Printf.sprintf "git push -u origin %s" (Filename.quote branch))
      = 0
    then Ok ()
    else Soldev_exit.error (Printf.sprintf "error: git push failed for %s" branch)
  in
  let content = read_file done_path in
  let* prs = open_prs () in
  match find_pr_in prs ticket_id with
  | Some p ->
    Printf.printf "[%s] PR already exists: %s\n%!" ticket_id p.pr_url;
    Ok ()
  | None ->
    Printf.printf "[%s] opening PR...\n%!" ticket_id;
    let title = Printf.sprintf "%s: %s" ticket_id (Soldev_ticket.ticket_title content) in
    let body =
      Printf.sprintf
        "Ticket: `%s`\n\n\
         See `internal/pipeline/tickets/DONE/%s.md` on this branch for the full spec — \
         it lands in `internal/pipeline/tickets/DONE/` on `main` as part of this PR's \
         squash-merge.\n"
        ticket_id
        ticket_id
    in
    let r =
      Sol_process.run_shell
        ~echo:false
        (Printf.sprintf
           "gh pr create --base main --head %s --title %s --body %s"
           (Filename.quote branch)
           (Filename.quote title)
           (Filename.quote body))
    in
    if Sol_process.succeeded r
    then (
      Printf.printf "[%s] → %s\n%!" ticket_id (String.trim r.Sol_process.stdout);
      Ok ())
    else Soldev_exit.error ("error: gh pr create failed:\n" ^ r.Sol_process.stderr)
;;

type review_status =
  | Pass
  | Fail

type violation =
  { vfile : string
  ; vline : int option
  ; vmessage : string
  }

let result_fields status j =
  let open Yojson.Basic.Util in
  let summary = j |> member "summary" |> to_string_option |> Option.value ~default:"" in
  let violations =
    (match j |> member "violations" with
     | `Null -> []
     | v -> to_list v)
    |> List.map (fun v ->
      { vfile = v |> member "file" |> to_string
      ; vline = v |> member "line" |> to_int_option
      ; vmessage = v |> member "message" |> to_string
      })
  in
  Ok (status, summary, violations)
;;

let parse_result json_str =
  let open Yojson.Basic.Util in
  let decode j =
    match j |> member "status" |> to_string with
    | "pass" -> result_fields Pass j
    | "fail" -> result_fields Fail j
    | other -> Soldev_exit.error (Printf.sprintf "error: unknown status %S" other)
  in
  match Yojson.Basic.from_string json_str with
  | exception Yojson.Json_error message ->
    Soldev_exit.error ("error: the review result is not JSON: " ^ message)
  | j ->
    (try decode j with
     | Type_error (message, _) ->
       Soldev_exit.error ("error: unexpected review result shape: " ^ message))
;;

let format_violations vs =
  String.concat
    "\n"
    (List.map
       (fun v ->
          match v.vline with
          | Some l -> Printf.sprintf "- `%s:%d` — %s" v.vfile l v.vmessage
          | None -> Printf.sprintf "- `%s` — %s" v.vfile v.vmessage)
       vs)
;;

let run_review ticket_id result_file =
  let open Result.Syntax in
  let* prs = open_prs () in
  match find_pr_in prs ticket_id with
  | None ->
    Soldev_exit.error
      (Printf.sprintf
         "error: no open PR found for %s (branch prefix %s/)"
         ticket_id
         ticket_id)
  | Some p ->
    let json_str =
      match result_file with
      | Some path -> read_file path
      | None ->
        let buf = Buffer.create 512 in
        (try
           while true do
             Buffer.add_channel buf stdin 4096
           done
         with
         | End_of_file -> ());
        Buffer.contents buf
    in
    let* status, summary, violations = parse_result (String.trim json_str) in
    (match status with
     | Pass ->
       let summary = if summary = "" then "Automated review: pass." else summary in
       let body = Printf.sprintf "%s %s\n\n%s" review_pass_marker p.pr_head_sha summary in
       let rc =
         Soldev_shell.run_cmd
           ~echo:false
           (Printf.sprintf
              "gh pr comment %s --body %s"
              (Filename.quote p.pr_url)
              (Filename.quote body))
       in
       if rc <> 0
       then
         Soldev_exit.error
           (Printf.sprintf "error: failed to post review-pass comment on %s" p.pr_url)
       else (
         Printf.printf "[%s] %s → review passed (informational)\n" ticket_id p.pr_url;
         Ok ())
     | Fail ->
       let body =
         Printf.sprintf
           "%s\n\nAutomated review: changes requested.\n\n%s"
           review_fail_marker
           (format_violations violations)
       in
       let rc =
         Soldev_shell.run_cmd
           ~echo:false
           (Printf.sprintf
              "gh pr comment %s --body %s"
              (Filename.quote p.pr_url)
              (Filename.quote body))
       in
       if rc <> 0
       then
         Soldev_exit.error
           (Printf.sprintf "error: failed to post review-fail comment on %s" p.pr_url)
       else (
         Printf.printf
           "[%s] %s → changes requested (%d violation(s))\n"
           ticket_id
           p.pr_url
           (List.length violations);
         Ok ()))
;;

type post_merge_action =
  | Record_baseline
  | Record_baseline_after_perf_regression
  | Report_local_failure of int

let post_merge_action_of_rc = function
  | 0 -> Record_baseline
  | 2 -> Record_baseline_after_perf_regression
  | rc -> Report_local_failure rc
;;

let run_merge_finish ~ticket_id ~merge_sha =
  let perf_rc = Soldev_shell.run_cmd "./internal/tooling/scripts/run_tests.sh" in
  match post_merge_action_of_rc perf_rc with
  | Report_local_failure rc ->
    Soldev_exit.error
      (Printf.sprintf
         "  local post-merge suite failed (rc=%d) — %s is NOT reverted.\n\
         \  The merge is on origin/main (the required checks verified it before it \
          landed) and the ticket's DONE move travelled with it: nothing is rolled back, \
          here or there.\n\
         \  This run reflects this machine — missing kafka/e2e infra is the usual cause \
          — not the code CI already verified.\n\
         \  If this is a real regression, revert it deliberately on the remote:\n\
         \    git revert %s && git push origin main"
         rc
         ticket_id
         merge_sha)
  | Record_baseline | Record_baseline_after_perf_regression ->
    if perf_rc = 2
    then
      Printf.eprintf
        "  perf regression detected (informational only — recording baseline, not \
         reverting)\n\
         %!";
    ignore
      (Soldev_shell.run_cmd
         ~echo:false
         "./internal/tooling/scripts/run_tests.sh --update-baseline");
    let message =
      if perf_rc = 2
      then
        Printf.sprintf
          "pipeline: update perf baseline after %s (perf regression recorded)"
          ticket_id
      else Printf.sprintf "pipeline: update perf baseline after %s" ticket_id
    in
    ignore
      (Soldev_shell.run_cmd
         ~echo:false
         (Printf.sprintf
            "git add internal/tooling/perf/perf_baseline.json && git commit -m %s"
            (Filename.quote message)));
    Printf.printf "  ✓  merged\n%!";
    Ok ()
;;

let merge_candidates ~dry_run ~auto_merge candidates =
  let errors = ref 0 in
  List.iter
    (fun (id, p) ->
       Printf.printf "\n[%s]\n%!" id;
       let ready =
         match Soldev_ticket.find_ticket id with
         | None -> false
         | Some (state, path) ->
           let content = read_file path in
           state <> Soldev_ticket.Backlog
           && Soldev_ticket.unreadable ~path content = None
           && (not (Soldev_ticket.has_human_decision_gate content))
           && (not (Option.is_some (Soldev_ticket.find_dependency_cycle id)))
           && List.for_all
                (fun dep -> Soldev_ticket.dependency_status dep = `Done)
                (Soldev_ticket.parse_depends content)
       in
       if not ready
       then Printf.printf "  ticket prerequisites unresolved — skipping (%s)\n" p.pr_url
       else if p.pr_draft
       then Printf.printf "  draft PR — skipping (%s)\n" p.pr_url
       else if (not auto_merge) && not (pr_checks_green p.pr_url)
       then Printf.printf "  required checks not green — skipping (%s)\n" p.pr_url
       else (
         let command = merge_command ~auto_merge p in
         if dry_run
         then Printf.printf "  (dry-run) %s\n" command
         else if Soldev_shell.run_cmd command <> 0
         then incr errors
         else
           Printf.printf
             "  GitHub accepted %s\n%!"
             (if auto_merge then "auto-merge" else "merge")))
    candidates;
  if !errors = 0
  then Ok ()
  else Soldev_exit.error (Printf.sprintf "error: %d merge request(s) failed" !errors)
;;

let run_merge ~dry_run ~auto_merge ~ticket_filter =
  let open Result.Syntax in
  let* prs = open_prs () in
  let* candidates =
    match ticket_filter with
    | Some id ->
      (match find_pr_in prs id with
       | Some p -> Ok [ id, p ]
       | None -> Soldev_exit.error (Printf.sprintf "error: no open PR found for %s" id))
    | None -> Ok (List.map (fun p -> ticket_id_of_branch p.pr_branch, p) prs)
  in
  if candidates = []
  then (
    Printf.printf "No open PRs to merge.\n";
    Ok ())
  else merge_candidates ~dry_run ~auto_merge candidates
;;

let parse_worktree_porcelain lines =
  let rec go current acc = function
    | [] ->
      List.rev
        (match current with
         | Some wt -> wt :: acc
         | None -> acc)
    | line :: rest ->
      if starts_with ~prefix:"worktree " line
      then (
        let path = String.sub line 9 (String.length line - 9) in
        let acc =
          match current with
          | Some wt -> wt :: acc
          | None -> acc
        in
        go (Some (path, None)) acc rest)
      else if starts_with ~prefix:"branch refs/heads/" line
      then (
        match current with
        | Some (path, None) ->
          let branch = String.sub line 18 (String.length line - 18) in
          go (Some (path, Some branch)) acc rest
        | _ -> go current acc rest)
      else go current acc rest
  in
  go None [] lines
;;

let shell_output_trim cmd = Sol_process.output_shell ~echo:false cmd |> String.trim

type worktree_snapshot =
  { ws_path : string
  ; ws_branch : string
  ; ws_dirty : bool
  ; ws_unpushed : bool
  }

let worktree_snapshot_of_entry = function
  | _, None -> None
  | path, Some branch ->
    let qpath = Filename.quote path in
    let status =
      shell_output_trim (Printf.sprintf "git -C %s status --porcelain" qpath)
    in
    let dirty = status <> "" in
    let upstream = "origin/" ^ branch in
    let upstream_rc =
      Sol_process.run_shell_rc
        ~echo:false
        (Printf.sprintf
           "git -C %s rev-parse --verify %s >/dev/null 2>&1"
           qpath
           (Filename.quote upstream))
    in
    let commits_ahead_of ref =
      let count =
        shell_output_trim
          (Printf.sprintf
             "git -C %s rev-list --count %s..HEAD"
             qpath
             (Filename.quote ref))
      in
      match int_of_string_opt count with
      | Some count -> count > 0
      | None -> true
    in
    let unpushed =
      commits_ahead_of (if upstream_rc = 0 then upstream else "origin/main")
    in
    Some { ws_path = path; ws_branch = branch; ws_dirty = dirty; ws_unpushed = unpushed }
;;

let worktree_snapshots () =
  Soldev_shell.run_cmd_lines "git worktree list --porcelain"
  |> parse_worktree_porcelain
  |> List.filter_map worktree_snapshot_of_entry
;;

let find_ticket_worktree ticket_id =
  worktree_snapshots ()
  |> List.find_opt (fun wt ->
    wt.ws_branch <> "main" && ticket_id_of_branch wt.ws_branch = ticket_id)
;;

let worktree_annotation_for_ticket ticket_id =
  match find_ticket_worktree ticket_id with
  | None -> None
  | Some wt ->
    let notes =
      (if wt.ws_dirty then [ "dirty worktree" ] else [])
      @ if wt.ws_unpushed then [ "unpushed commits" ] else []
    in
    if notes = []
    then None
    else Some (Printf.sprintf "(%s @ %s)" (String.concat ", " notes) wt.ws_path)
;;

let run_ls include_done =
  let open Result.Syntax in
  let* prs = open_prs () in
  let states =
    if include_done
    then Soldev_ticket.all_states
    else List.filter (fun s -> s <> Soldev_ticket.Done) Soldev_ticket.all_states
  in
  let any = ref false in
  let unreadable = ref [] in
  List.iter
    (fun state ->
       let state_dir = ticket_dir state in
       if Sys.file_exists state_dir
       then (
         let files =
           Sys.readdir state_dir
           |> Array.to_list
           |> List.filter (fun f -> Filename.check_suffix f ".md")
           |> List.sort String.compare
         in
         if files <> []
         then (
           any := true;
           Printf.printf "\n%s (%d)\n" (dir state) (List.length files);
           List.iter
             (fun filename ->
                let id = Filename.chop_suffix filename ".md" in
                let content = read_file (Filename.concat state_dir filename) in
                let fields = Soldev_ticket.fields content in
                let typ =
                  Soldev_ticket.fm_get fields "type" |> Option.value ~default:"-"
                in
                let sev =
                  Soldev_ticket.fm_get fields "severity" |> Option.value ~default:"-"
                in
                let deps =
                  Soldev_ticket.parse_depends content |> Soldev_ticket.dependency_summary
                in
                let path = Filename.concat state_dir filename in
                let ready =
                  match Soldev_ticket.unreadable ~path content with
                  | Some reason ->
                    unreadable := reason :: !unreadable;
                    reason
                  | None ->
                    let ready =
                      Soldev_ticket.readiness_label ~ticket_id:id state content
                    in
                    let ready =
                      match Soldev_ticket.premise_of content with
                      | None -> ready
                      | Some probe ->
                        (match
                           Soldev_ticket.premise_verdict
                             ~exit_code:(Soldev_shell.run_cmd ~echo:false probe)
                         with
                         | Soldev_ticket.Premise_holds -> ready
                         | Soldev_ticket.Premise_stale ->
                           "premise-stale — the probe succeeded, so this may be done \
                            already"
                         | Soldev_ticket.Premise_unverified reason ->
                           "premise-unverified: " ^ reason)
                    in
                    let ready =
                      if state = Soldev_ticket.Ready_for_engineering
                      then (
                        match find_pr_in prs id with
                        | Some p -> ready ^ Printf.sprintf " (PR #%d open)" p.pr_number
                        | None -> ready)
                      else ready
                    in
                    (match worktree_annotation_for_ticket id with
                     | Some annotation -> ready ^ " " ^ annotation
                     | None -> ready)
                in
                let title = Soldev_ticket.ticket_title content in
                Printf.printf
                  "  %-12s  %-18s  %-7s  depends on: %-24s  %-24s  %s\n"
                  id
                  typ
                  sev
                  deps
                  ready
                  title)
             files)))
    states;
  if not !any then Printf.printf "No tickets found.\n";
  match List.rev !unreadable with
  | [] -> Ok ()
  | tickets ->
    List.iter (fun reason -> Printf.eprintf "error: %s\n%!" reason) tickets;
    Soldev_exit.error
      ~code:1
      (Printf.sprintf
         "%d ticket(s) in the states listed above could not be read; fix them, or run \
          `soldev pipeline validate` for the whole tree"
         (List.length tickets))
;;

let run_validate () =
  let missing_dirs =
    Soldev_ticket.all_states
    |> List.filter_map (fun state ->
      let state_dir = ticket_dir state in
      if Sys.file_exists state_dir
      then None
      else Some (Printf.sprintf "%s: no such ticket directory" state_dir))
  in
  let paths =
    Soldev_ticket.all_states
    |> List.concat_map (fun state ->
      let state_dir = ticket_dir state in
      if not (Sys.file_exists state_dir)
      then []
      else
        Sys.readdir state_dir
        |> Array.to_list
        |> List.filter (fun f -> Filename.check_suffix f ".md")
        |> List.sort String.compare
        |> List.map (Filename.concat state_dir))
  in
  let unreadable =
    missing_dirs
    @ List.filter_map (fun path -> Soldev_ticket.unreadable ~path (read_file path)) paths
  in
  List.iter (fun reason -> Printf.eprintf "error: %s\n%!" reason) unreadable;
  match unreadable with
  | [] ->
    Printf.printf
      "pipeline tickets: %d read across %d state(s) — all readable\n"
      (List.length paths)
      (List.length Soldev_ticket.all_states);
    Ok ()
  | _ ->
    Soldev_exit.error
      ~code:1
      (Printf.sprintf
         "%d of %d pipeline tickets could not be read"
         (List.length unreadable)
         (List.length paths))
;;

let run_check ticket_id =
  let open Result.Syntax in
  match Soldev_ticket.find_ticket ticket_id with
  | None -> Soldev_exit.error ~code:2 (Printf.sprintf "unknown ticket: %s" ticket_id)
  | Some (state, path) ->
    let content = read_file path in
    let* () =
      match Soldev_ticket.unreadable ~path content with
      | None -> Ok ()
      | Some message -> Soldev_exit.error message
    in
    let deps = Soldev_ticket.parse_depends content in
    Printf.printf "%s  state: %s\n" ticket_id (dir state);
    Printf.printf "depends on: %s\n" (Soldev_ticket.dependency_summary deps);
    let* prs = open_prs () in
    (match find_pr_in prs ticket_id with
     | Some p -> Printf.printf "open PR: %s\n" p.pr_url
     | None -> ());
    (match worktree_annotation_for_ticket ticket_id with
     | Some annotation -> Printf.printf "worktree: %s\n" annotation
     | None -> ());
    let* () =
      match Soldev_ticket.premise_of content with
      | None -> Ok ()
      | Some probe ->
        (match Soldev_ticket.premise_verdict ~exit_code:(Soldev_shell.run_cmd probe) with
         | Soldev_ticket.Premise_holds ->
           Printf.printf "premise: holds\n";
           Ok ()
         | Soldev_ticket.Premise_stale ->
           Printf.printf
             "premise stale: the probe succeeded, so the work this ticket describes may \
              already be done. Re-read the ticket and either close it with evidence or \
              fix the probe.\n";
           Printf.printf "status: premise-stale\n";
           Soldev_exit.reported ()
         | Soldev_ticket.Premise_unverified reason ->
           Printf.printf
             "premise unverified: %s. Confirm the premise by hand before starting, then \
              fix or remove the probe.\n"
             reason;
           Printf.printf "status: premise-unverified\n";
           Soldev_exit.reported ())
    in
    let* () =
      if Soldev_ticket.has_human_decision_gate content
      then (
        let details = Soldev_ticket.human_decision_details content in
        if String.trim details <> "" then Printf.printf "\n%s\n\n" details;
        Printf.printf "status: blocked-for-human-decision\n";
        Soldev_exit.reported ())
      else Ok ()
    in
    let* () =
      match Soldev_ticket.find_dependency_cycle ticket_id with
      | Some cycle when Soldev_ticket.cycle_blocks cycle ->
        Printf.printf "dependency cycle: %s\n" (String.concat " -> " cycle);
        Printf.printf
          "  every member waits on the next, so none of them can start. Check each \
           `Depends on:` line in the cycle: an id mentioned as prose (`Implemented by \
           X`, `Related: X`) is read as a dependency.\n";
        Printf.printf "status: blocked-by-dependency-cycle\n";
        Soldev_exit.reported ()
      | _ -> Ok ()
    in
    let blocked =
      deps
      |> List.filter_map (fun dep ->
        match Soldev_ticket.dependency_status dep with
        | `Done -> None
        | `Unknown -> Some (dep, "UNKNOWN")
        | `Blocked state -> Some (dep, dir state))
    in
    if blocked <> []
    then (
      List.iter
        (fun (dep, state) -> Printf.printf "blocked by dependency: %s in %s\n" dep state)
        blocked;
      Printf.printf "status: blocked-by-dependency\n";
      Soldev_exit.reported ())
    else if state = Soldev_ticket.Ready_for_engineering
    then (
      Printf.printf "status: actionable\n";
      Ok ())
    else (
      Printf.printf "status: not-ready-state\n";
      Soldev_exit.reported ())
;;
