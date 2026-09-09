let read_file  = Soldev_shell.read_file

let dir state = Soldev_ticket.state_to_dir state

let ticket_dir state = Filename.concat "pipeline/tickets" (dir state)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let current_branch () =
  Sol_process.output_shell ~echo:false "git rev-parse --abbrev-ref HEAD 2>/dev/null"

let git_branch_exists branch =
  Sol_process.run_shell_rc ~echo:false
    (Printf.sprintf "git rev-parse --verify %s >/dev/null 2>&1" (Filename.quote branch)) = 0

(* ── PR lookup (see REFAC-077) ───────────────────────────────────────────────

   Since a ticket in flight no longer carries `branch:`/`pr:` frontmatter on
   `main` (there is nothing to persist there until it lands in DONE), finding
   a ticket's PR means asking GitHub directly rather than reading a local
   field. A branch's convention is `<TICKET-ID>/<slug>`, so the ticket ID is
   the path segment before the first `/`. *)

type pr_info =
  { pr_number : int; pr_url : string; pr_branch : string; pr_head_sha : string }

let ticket_id_of_branch branch =
  match String.index_opt branch '/' with
  | Some i -> String.sub branch 0 i
  | None -> branch

let open_prs () =
  let json_str =
    Sol_process.output_shell ~echo:false
      "gh pr list --state open --json number,url,headRefName,headRefOid --limit 200"
  in
  if json_str = "" then []
  else
    let open Yojson.Basic.Util in
    Yojson.Basic.from_string json_str |> to_list
    |> List.map (fun j ->
      { pr_number  = j |> member "number" |> to_int
      ; pr_url     = j |> member "url" |> to_string
      ; pr_branch  = j |> member "headRefName" |> to_string
      ; pr_head_sha = j |> member "headRefOid" |> to_string })

let find_pr_for_ticket ticket_id =
  open_prs () |> List.find_opt (fun p -> ticket_id_of_branch p.pr_branch = ticket_id)

(* `gh pr checks` exits 0 iff every required check has completed and passed —
   pending or failing checks give a non-zero exit. That is exactly the
   "is this actually ready" signal `merge` needs; no need to parse the JSON
   ourselves. *)
let pr_checks_green pr_url =
  Sol_process.run_shell_rc ~echo:false
    (Printf.sprintf "gh pr checks %s >/dev/null 2>&1" (Filename.quote pr_url)) = 0

(* This is a solo-owned repo: the `gh` identity running review/merge is
   always the PR's own author, and GitHub refuses to let an author formally
   approve their own PR (`gh pr review --approve` fails with "Can not
   approve your own pull request"). So review readiness can't be GitHub's
   own reviewDecision — it's a plain PR comment carrying this marker,
   posted by `run_review` and checked for here. Branch protection's
   1-approval requirement is separately satisfied at merge time via
   `gh pr merge --admin`, same as before.

   A pass comment is only trustworthy for the exact commit it reviewed: a
   bounce-then-refix round posts a *later* comment on the same PR, and a
   naive "does a PASS exist anywhere in history" check would still see the
   earlier PASS and call the PR approved even though the latest verdict is
   FAIL, or even though HEAD moved past the reviewed commit entirely (a
   rebase, a manual fixup, any commit nobody re-reviewed). So: only the
   temporally-last SOLDEV-REVIEW comment counts, and a PASS only counts if
   its embedded sha still equals the PR's current head. *)
let review_pass_marker = "SOLDEV-REVIEW: PASS"
let review_fail_marker = "SOLDEV-REVIEW: FAIL"

type review_verdict = Reviewed_pass of string (* reviewed sha *) | Reviewed_fail

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let parse_review_marker body =
  match String.split_on_char '\n' body with
  | [] -> None
  | first_line :: _ ->
    if starts_with ~prefix:review_pass_marker first_line then
      let rest_start = String.length review_pass_marker in
      let sha =
        String.sub first_line rest_start (String.length first_line - rest_start)
        |> String.trim
      in
      Some (Reviewed_pass sha)
    else if starts_with ~prefix:review_fail_marker first_line then
      Some Reviewed_fail
    else None

(* Later comments override earlier ones — this is what makes a bounce
   correctly supersede a prior pass. *)
let latest_review_verdict_of_bodies bodies =
  List.fold_left (fun acc body ->
    match parse_review_marker body with
    | Some v -> Some v
    | None -> acc)
    None bodies

let pr_comment_bodies pr_url =
  let json_str =
    Sol_process.output_shell ~echo:false
      (Printf.sprintf "gh pr view %s --json comments" (Filename.quote pr_url))
  in
  if json_str = "" then []
  else
    let open Yojson.Basic.Util in
    Yojson.Basic.from_string json_str
    |> member "comments" |> to_list
    |> List.map (fun c -> c |> member "body" |> to_string)

let pr_review_approved pr =
  match latest_review_verdict_of_bodies (pr_comment_bodies pr.pr_url) with
  | Some (Reviewed_pass reviewed_sha) -> reviewed_sha = pr.pr_head_sha
  | Some Reviewed_fail | None -> false

(* ── pipeline check-reverts ──────────────────────────────────────────────── *)

(* `Revert "Merge branch 'EXP-023/cloud-init-kubeconfig'..."` -> "EXP-023" *)
let ticket_id_from_branch branch = ticket_id_of_branch branch

let extract_reverted_branch subject =
  let marker = "Revert \"Merge branch '" in
  let mlen = String.length marker in
  let slen = String.length subject in
  if slen >= mlen && String.sub subject 0 mlen = marker then
    match String.index_from_opt subject mlen '\'' with
    | Some close -> Some (String.sub subject mlen (close - mlen))
    | None -> None
  else None

let is_id_char c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
  || c = '_' || c = '-'

(* Whole-token substring match: "AUDIT-023" must not match inside
   "CODEX_STYLE_AUDIT-023" or "AUDIT-0231". *)
let mentions_id ~id line =
  let idlen = String.length id and linelen = String.length line in
  let rec go p =
    if p + idlen > linelen then false
    else if String.sub line p idlen = id
            && (p = 0 || not (is_id_char line.[p - 1]))
            && (p + idlen = linelen || not (is_id_char line.[p + idlen]))
    then true
    else go (p + 1)
  in
  go 0

(* This repo routinely reverts a merge on a test failure and then reapplies
   the fix in a later "Reapply ..." commit — that pattern is healthy and must
   not be flagged. Only a revert with no later commit mentioning the ticket id
   is a real "never refixed" case.

   Since REFAC-077, a ticket's DONE move is committed on the same commit as
   its code, so a revert here already un-does both atomically — this check
   should rarely if ever fire going forward. Kept as defense in depth, not
   because it's still load-bearing the way it was for EXP-032. *)
let refixed_after ~id ~revert_hash =
  Soldev_shell.run_cmd_lines
    (Printf.sprintf "git log --oneline %s" (Filename.quote (revert_hash ^ "..HEAD")))
  |> List.exists (mentions_id ~id)

let run_check_reverts () =
  let lines =
    Soldev_shell.run_cmd_lines
      (Printf.sprintf "git log --oneline -E --grep=%s"
         (Filename.quote "^Revert \"Merge branch"))
  in
  let flagged =
    lines |> List.filter_map (fun line ->
      match String.index_opt line ' ' with
      | None -> None
      | Some i ->
        let hash = String.sub line 0 i in
        let subject = String.sub line (i + 1) (String.length line - i - 1) in
        match extract_reverted_branch subject with
        | None -> None
        | Some branch ->
          let id = ticket_id_from_branch branch in
          let done_path = Filename.concat (ticket_dir Soldev_ticket.Done) (id ^ ".md") in
          if Sys.file_exists done_path && not (refixed_after ~id ~revert_hash:hash)
          then Some (id, hash, done_path) else None)
  in
  if flagged = [] then
    Printf.printf "check-reverts: clean — no DONE ticket has a matching revert commit.\n"
  else begin
    Printf.printf
      "check-reverts: %d ticket(s) marked DONE have a merge that was later reverted:\n"
      (List.length flagged);
    List.iter (fun (id, hash, path) ->
      Printf.printf
        "  %-12s  revert %s  still in %s — verify the fix is actually live in main, or move it back to READY_FOR_ENGINEERING\n"
        id hash path)
      flagged;
    exit 1
  end

(* ── pipeline submit ──────────────────────────────────────────────────────── *)

(* Run from WITHIN the ticket's worktree (not the main checkout — see
   REFAC-077). The worker's own last implementation commit already moved the
   ticket file from READY_FOR_ENGINEERING/ to DONE/ *on this branch*; submit's
   only job is to push the branch and open the PR (or reuse an existing one).
   It never touches `pipeline/tickets/` on `main` — there is nothing to move
   there until the PR actually merges. *)
let run_submit ticket_id =
  let done_path = Printf.sprintf "%s/%s.md" (ticket_dir Soldev_ticket.Done) ticket_id in
  if not (Sys.file_exists done_path) then begin
    Printf.eprintf
      "error: %s not found. Run this from the ticket's worktree, after your \
       final commit has already moved the ticket file to DONE/ on this branch.\n"
      done_path;
    exit 1
  end;
  let branch = current_branch () in
  if branch = "main" || branch = "" then begin
    Printf.eprintf "error: not on a ticket branch (currently on %s)\n" branch; exit 1
  end;
  Printf.printf "[%s] pushing %s...\n%!" ticket_id branch;
  if Soldev_shell.run_cmd (Printf.sprintf "git push -u origin %s" (Filename.quote branch)) <> 0 then begin
    Printf.eprintf "error: git push failed for %s\n" branch; exit 1
  end;
  let content = read_file done_path in
  match find_pr_for_ticket ticket_id with
  | Some p ->
    Printf.printf "[%s] PR already exists: %s\n%!" ticket_id p.pr_url
  | None ->
    Printf.printf "[%s] opening PR...\n%!" ticket_id;
    let title = Printf.sprintf "%s: %s" ticket_id (Soldev_ticket.ticket_title content) in
    let body = Printf.sprintf
      "Ticket: `%s`\n\nSee `pipeline/tickets/DONE/%s.md` on this branch for the full spec — \
       it lands in `pipeline/tickets/DONE/` on `main` as part of this PR's squash-merge.\n"
      ticket_id ticket_id in
    let r = Sol_process.run_shell ~echo:false (Printf.sprintf
      "gh pr create --base main --head %s --title %s --body %s"
      (Filename.quote branch) (Filename.quote title) (Filename.quote body)) in
    if not (Sol_process.succeeded r) then begin
      Printf.eprintf "error: gh pr create failed:\n%s\n" r.Sol_process.stderr; exit 1
    end;
    Printf.printf "[%s] → %s\n%!" ticket_id (String.trim r.Sol_process.stdout)

(* ── pipeline review ──────────────────────────────────────────────────────── *)

type review_status = Pass | Fail

type violation = { vfile: string; vline: int option; vmessage: string }

let parse_result json_str =
  let open Yojson.Basic.Util in
  let j = Yojson.Basic.from_string json_str in
  let status_raw = j |> member "status" |> to_string in
  let status =
    match status_raw with
    | "pass" -> Pass
    | "fail" -> Fail
    | _ -> Printf.eprintf "error: unknown status %S\n" status_raw; exit 1
  in
  let summary = j |> member "summary" |> to_string_option |> Option.value ~default:"" in
  let violations =
    (match j |> member "violations" with
     | `Null -> []
     | v -> to_list v)
    |> List.map (fun v ->
      { vfile    = v |> member "file" |> to_string
      ; vline    = (try Some (v |> member "line" |> to_int) with _ -> None)
      ; vmessage = v |> member "message" |> to_string })
  in
  (status, summary, violations)

let format_violations vs =
  String.concat "\n" (List.map (fun v ->
    match v.vline with
    | Some l -> Printf.sprintf "- `%s:%d` — %s" v.vfile l v.vmessage
    | None   -> Printf.sprintf "- `%s` — %s" v.vfile v.vmessage
  ) vs)

(* Review leaves its verdict on the PR itself as a plain comment — not a
   formal GitHub review, since self-approval is impossible here (see
   pr_review_approved) — instead of moving any ticket file. There is nothing
   to move: the ticket's DONE move already happened on the branch when it
   was implemented, and a bounce just means the same open PR gets another
   commit (this repo's established convention), not a ticket-directory
   round trip. *)
let run_review ticket_id result_file =
  match find_pr_for_ticket ticket_id with
  | None ->
    Printf.eprintf "error: no open PR found for %s (branch prefix %s/)\n" ticket_id ticket_id;
    exit 1
  | Some p ->
    let json_str =
      match result_file with
      | Some path -> read_file path
      | None ->
        let buf = Buffer.create 512 in
        (try while true do Buffer.add_channel buf stdin 4096 done with End_of_file -> ());
        Buffer.contents buf
    in
    let (status, summary, violations) = parse_result (String.trim json_str) in
    (match status with
     | Pass ->
       (* Embed the PR's current head sha (from GitHub, not the local
          worktree — see REFAC-077 follow-up) so a later commit nobody
          reviewed can never ride in on this comment's approval. *)
       let body =
         Printf.sprintf "%s %s\n\n%s" review_pass_marker p.pr_head_sha
           (if summary = "" then "Automated review: pass." else summary)
       in
       let rc = Soldev_shell.run_cmd ~echo:false
         (Printf.sprintf "gh pr comment %s --body %s"
            (Filename.quote p.pr_url) (Filename.quote body))
       in
       if rc <> 0 then begin
         Printf.eprintf "error: failed to post review-pass comment on %s\n" p.pr_url;
         exit 1
       end;
       Printf.printf "[%s] %s → approved\n" ticket_id p.pr_url
     | Fail ->
       let body =
         Printf.sprintf "%s\n\nAutomated review: changes requested.\n\n%s"
           review_fail_marker (format_violations violations)
       in
       let rc = Soldev_shell.run_cmd ~echo:false
         (Printf.sprintf "gh pr comment %s --body %s"
            (Filename.quote p.pr_url) (Filename.quote body))
       in
       if rc <> 0 then begin
         Printf.eprintf "error: failed to post review-fail comment on %s\n" p.pr_url;
         exit 1
       end;
       Printf.printf "[%s] %s → changes requested (%d violation(s))\n"
         ticket_id p.pr_url (List.length violations))

(* ── pipeline merge-finish (internal — spawned by `merge`, never call directly) ──

   Runs the post-merge test suite and updates the perf baseline. `merge`
   always invokes this as a subprocess of a binary rebuilt *after* the PR's
   merge commit landed — never inline in the resident pre-merge process (see
   REFAC-075). There is no ticket file to move here any more: the squash
   commit `merge` just applied already carried the ticket's own
   READY_FOR_ENGINEERING -> DONE move (committed by the worker, on the
   branch). On a real regression, reverting that squash commit un-does the
   code *and* the ticket's DONE move together, landing it back in
   READY_FOR_ENGINEERING for free — no BLOCKED_BY_PERFORMANCE state needed. *)
let run_merge_finish label merge_sha accept_performance_regression =
  let perf_rc = Soldev_shell.run_cmd "./cli/platform/local/scripts/run_tests.sh" in
  if perf_rc = 2 && accept_performance_regression then begin
    Printf.eprintf "  perf regression explicitly accepted — recording new baseline\n%!";
    ignore (Soldev_shell.run_cmd ~echo:false
      "./cli/platform/local/scripts/run_tests.sh --update-baseline");
    ignore (Soldev_shell.run_cmd ~echo:false
      (Printf.sprintf "git add devtools/perf/perf_baseline.json && git commit -m %s"
        (Filename.quote
          (Printf.sprintf "pipeline: update perf baseline after %s (perf regression accepted)" label))));
    Printf.printf "  ✓  merged\n%!";
    exit 0
  end else if perf_rc >= 1 then begin
    let kind = if perf_rc = 2 then "perf regression" else "test failure" in
    (* run_tests.sh always appends a non-baseline history entry to
       devtools/perf/perf_baseline.json, even here, leaving it locally
       modified. That made `git revert` fail with "local changes would be
       overwritten by merge" every time this path fired (CODE_LAYER-011) —
       discard it before reverting. *)
    ignore (Soldev_shell.run_cmd ~echo:false
      "git checkout -- devtools/perf/perf_baseline.json");
    let revert_rc = Soldev_shell.run_cmd ~echo:false (Printf.sprintf
      "SOL_SKIP_HOOKS=1 git revert %s --no-edit" (Filename.quote merge_sha)) in
    Printf.eprintf "  %s detected — reverted %s (ticket returns to READY_FOR_ENGINEERING with it)\n%!"
      kind merge_sha;
    if revert_rc <> 0 then
      Printf.eprintf "  warning: %s remains merged because automatic revert failed\n%!" label;
    exit 1
  end else begin
    ignore (Soldev_shell.run_cmd ~echo:false
      "./cli/platform/local/scripts/run_tests.sh --update-baseline");
    ignore (Soldev_shell.run_cmd ~echo:false
      (Printf.sprintf "git add devtools/perf/perf_baseline.json && git commit -m %s"
        (Filename.quote (Printf.sprintf "pipeline: update perf baseline after %s" label))));
    Printf.printf "  ✓  merged\n%!";
    exit 0
  end

(* Path to the binary `dune build` just refreshed. Invoked directly rather
   than via the `soldev` name on PATH, so this doesn't depend on
   ~/.local/bin/soldev being symlinked at all. *)
let freshly_built_soldev = "_build/default/devtools/soldev/bin/main.exe"

(* ── pipeline merge ──────────────────────────────────────────────────────── *)

(* Merges via `gh pr merge` — GitHub branch protection and required checks
   gate the actual merge, not local logic. A ticket is candidate for merging
   the moment it has an open PR with an approved review and green checks;
   there is no local READY_TO_MERGE directory to enumerate any more (see
   REFAC-077) — `merge` asks GitHub directly. Pass a ticket ID to merge one;
   omit to sweep every open PR whose branch looks like `<TICKET-ID>/...`. *)
let run_merge dry_run accept_performance_regression ticket_filter =
  let candidates =
    match ticket_filter with
    | Some id ->
      (match find_pr_for_ticket id with
       | Some p -> [ (id, p) ]
       | None ->
         Printf.eprintf "error: no open PR found for %s\n" id; exit 1)
    | None ->
      open_prs ()
      |> List.map (fun p -> (ticket_id_of_branch p.pr_branch, p))
  in
  if candidates = [] then begin
    Printf.printf "No open PRs to merge.\n"; exit 0
  end;
  let branch = current_branch () in
  if branch <> "main" then begin
    Printf.eprintf "error: must be on main to merge (currently on %s).\n" branch; exit 1
  end;
  let errors = ref 0 in
  let merged = ref [] in
  List.iter (fun (id, p) ->
    Printf.printf "\n[%s]\n%!" id;
    if not (pr_review_approved p) then begin
      Printf.printf "  not approved yet — skipping (%s)\n" p.pr_url
    end else if not (pr_checks_green p.pr_url) then begin
      Printf.printf "  checks not green yet — skipping (%s)\n" p.pr_url
    end else if dry_run then begin
      Printf.printf "  (dry-run) gh pr merge %s --squash --delete-branch\n" p.pr_url
    end else begin
      (* `gh pr merge --delete-branch` fails outright — nonzero exit, even
         though the merge itself already landed on GitHub — if the branch is
         still checked out in a linked worktree. That's not an edge case:
         it's the normal state of any ticket that just finished. Remove the
         worktree *before* calling `gh pr merge` so branch deletion never
         conflicts with it in the first place. *)
      Soldev_shell.run_cmd_lines "git worktree list --porcelain"
      |> List.filter_map (fun line ->
           if String.length line > 9 && String.sub line 0 9 = "worktree "
           then Some (String.sub line 9 (String.length line - 9)) else None)
      |> List.iter (fun wt_path ->
           let wt_branch = Sol_process.output_shell ~echo:false
             (Printf.sprintf "git -C %s rev-parse --abbrev-ref HEAD 2>/dev/null" (Filename.quote wt_path)) in
           if wt_branch = p.pr_branch then
             ignore (Soldev_shell.run_cmd (Printf.sprintf
               "git worktree remove %s --force" (Filename.quote wt_path))));
      let merge_rc = Soldev_shell.run_cmd (Printf.sprintf
        "gh pr merge %s --squash --delete-branch --admin" (Filename.quote p.pr_url)) in
      if merge_rc <> 0 then begin
        Printf.eprintf "  gh pr merge failed for %s — leaving open, retry once green\n" p.pr_url;
        incr errors
      end else begin
        ignore (Soldev_shell.run_cmd ~echo:false "git fetch origin main -q");
        let sync_rc = Soldev_shell.run_cmd ~echo:false "git merge origin/main --no-edit -q" in
        if sync_rc <> 0 then begin
          Printf.eprintf "  merged on GitHub but failed to sync local main — resolve manually\n";
          incr errors
        end else begin
          let merge_sha = Sol_process.output_shell ~echo:false "git rev-parse origin/main" in
          Printf.printf "  rebuilding before post-merge checks...\n%!";
          let build_rc = Soldev_shell.run_cmd "dune build" in
          if build_rc <> 0 then begin
            Printf.eprintf "  post-merge build failed — reverting %s\n%!" merge_sha;
            ignore (Soldev_shell.run_cmd ~echo:false
              "git checkout -- devtools/perf/perf_baseline.json");
            let revert_rc = Soldev_shell.run_cmd ~echo:false (Printf.sprintf
              "SOL_SKIP_HOOKS=1 git revert %s --no-edit" (Filename.quote merge_sha)) in
            if revert_rc <> 0 then
              Printf.eprintf "  warning: %s remains merged because automatic revert failed\n%!" id;
            incr errors
          end else begin
            let finish_rc = Soldev_shell.run_cmd (Printf.sprintf
              "%s pipeline merge-finish %s %s%s"
              (Filename.quote freshly_built_soldev) (Filename.quote id)
              (Filename.quote merge_sha)
              (if accept_performance_regression then " --accept-performance-regression" else ""))
            in
            if finish_rc = 0 then merged := id :: !merged else incr errors
          end
        end
      end
    end
  ) candidates;
  if !errors > 0 then Printf.eprintf "\n%d ticket(s) had errors.\n" !errors;
  if (not dry_run) && !merged <> [] then
    Printf.printf "\nLocal main has new commits — remember to `git push origin main`.\n";
  Printf.printf "\nDone. %d merged.\n" (List.length !merged)

(* ── pipeline ls ─────────────────────────────────────────────────────────── *)

let run_ls include_done =
  let states =
    if include_done then Soldev_ticket.all_states
    else List.filter (fun s -> s <> Soldev_ticket.Done) Soldev_ticket.all_states
  in
  let any = ref false in
  List.iter (fun state ->
    let state_dir = ticket_dir state in
    if Sys.file_exists state_dir then begin
      let files =
        Sys.readdir state_dir |> Array.to_list
        |> List.filter (fun f -> Filename.check_suffix f ".md")
        |> List.sort String.compare
      in
      if files <> [] then begin
        any := true;
        Printf.printf "\n%s (%d)\n" (dir state) (List.length files);
        List.iter (fun filename ->
          let id      = Filename.chop_suffix filename ".md" in
          let content = read_file (Filename.concat state_dir filename) in
          let fields  = Soldev_ticket.parse_frontmatter content in
          let typ     = Soldev_ticket.fm_get fields "type"     |> Option.value ~default:"-" in
          let sev     = Soldev_ticket.fm_get fields "severity" |> Option.value ~default:"-" in
          let deps    = Soldev_ticket.parse_depends content |> Soldev_ticket.dependency_summary in
          let ready   = Soldev_ticket.readiness_label state content in
          let ready   =
            if state = Soldev_ticket.Ready_for_engineering then
              match find_pr_for_ticket id with
              | Some p -> ready ^ Printf.sprintf " (PR #%d open)" p.pr_number
              | None -> ready
            else ready
          in
          let title   = Soldev_ticket.ticket_title content in
          Printf.printf "  %-12s  %-18s  %-7s  depends on: %-24s  %-24s  %s\n"
            id typ sev deps ready title
        ) files
      end
    end
  ) states;
  if not !any then Printf.printf "No tickets found.\n"

(* ── pipeline check ──────────────────────────────────────────────────────── *)

let run_check ticket_id =
  match Soldev_ticket.find_ticket ticket_id with
  | None ->
    Printf.eprintf "unknown ticket: %s\n" ticket_id; exit 2
  | Some (state, path) ->
    let content = read_file path in
    let deps = Soldev_ticket.parse_depends content in
    Printf.printf "%s  state: %s\n" ticket_id (dir state);
    Printf.printf "depends on: %s\n" (Soldev_ticket.dependency_summary deps);
    (match find_pr_for_ticket ticket_id with
     | Some p -> Printf.printf "open PR: %s\n" p.pr_url
     | None -> ());
    if Soldev_ticket.has_human_decision_gate content then begin
      let details = Soldev_ticket.human_decision_details content in
      if String.trim details <> "" then Printf.printf "\n%s\n\n" details;
      Printf.printf "status: blocked-for-human-decision\n";
      exit 1
    end;
    let blocked =
      deps |> List.filter_map (fun dep ->
        match Soldev_ticket.dependency_status dep with
        | `Done -> None
        | `Unknown -> Some (dep, "UNKNOWN")
        | `Blocked state -> Some (dep, dir state))
    in
    if blocked <> [] then begin
      List.iter (fun (dep, state) ->
        Printf.printf "blocked by dependency: %s in %s\n" dep state) blocked;
      Printf.printf "status: blocked-by-dependency\n";
      exit 1
    end;
    if state = Soldev_ticket.Ready_for_engineering then
      Printf.printf "status: actionable\n"
    else begin
      Printf.printf "status: not-ready-state\n"; exit 1
    end
