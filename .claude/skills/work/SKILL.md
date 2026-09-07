---
description: Unified ticket worker. Dispatches based on ticket state — creates worktrees for READY_FOR_ENGINEERING tickets, resumes IN_PROGRESS ones, and runs the review agent on REVIEW tickets. One command for the full development loop.
---

# /work — Unified ticket worker

Single entry point for the development loop. Pass ticket IDs, a group selector, or nothing to get a menu. Dispatches each ticket to the right action based on its current state.

## Usage

```
/work                        # list all active tickets across states; user picks
/work all                    # process every ticket in READY_FOR_ENGINEERING/, IN_PROGRESS/, and REVIEW/
/work FEAT-002               # dispatch one ticket by ID
/work EXP-005 EXP-007        # dispatch multiple tickets
/work open                   # all tickets in READY_FOR_ENGINEERING/
/work open-exp               # all EXP-* tickets in READY_FOR_ENGINEERING/
/work open-audit             # all AUDIT-* tickets in READY_FOR_ENGINEERING/
/work in-progress            # all tickets in IN_PROGRESS/
/work review                 # all tickets in REVIEW/
```

## Step 1 — Resolve tickets and their states

For each ID given:
- Check `READY_FOR_ENGINEERING/`, `IN_PROGRESS/`, `REVIEW/` in order — use the first match.
- If found in `READY_TO_MERGE/`, `BLOCKED_BY_PERFORMANCE/`, or `DONE/` — skip and print a note.
- If not found anywhere — print an error.

For `all` — glob all three active directories (`READY_FOR_ENGINEERING/`, `IN_PROGRESS/`, `REVIEW/`) and process every ticket found.

For group selectors (`open`, `open-exp`, `open-audit`, `in-progress`, `review`) — glob the corresponding directory.

If no args given — list all tickets across `READY_FOR_ENGINEERING/`, `IN_PROGRESS/`, and `REVIEW/` grouped by state, then stop and let the user choose.

Use deterministic pipeline tooling for ticket status whenever possible:

```bash
soldev pipeline ls
```

This command prints ticket state, dependency status, human-decision blockers, and actionable status. Do not reconstruct dependency graphs by interpretation when this command is available.

## Step 2 — Dispatch by state

### READY_FOR_ENGINEERING → create worktree + implement

Before creating a worktree, run the deterministic ticket preflight:

```bash
soldev pipeline check <ticket-id>
```

Only create a worktree if the command exits 0 and prints `status: actionable`.

If it reports `blocked-for-human-decision`, `blocked-by-dependency`, `unknown ticket`, or any non-actionable status:
- Do not create a worktree.
- Do not move the ticket to `IN_PROGRESS/`.
- Print the command output for the user.
- Leave the ticket in its current directory.

1. Determine branch slug from ticket title (lowercase, hyphens).
2. Create worktree:
   ```bash
   git worktree add -b ticket-id/short-slug ../sol-ticket-id-short-slug main
   ```
3. Update ticket frontmatter with `branch:` and `worktree:`, move file to `IN_PROGRESS/`.
4. Commit the ticket state change in the main checkout.
5. Implement the ticket in the worktree — read the ticket's **Remediation** as the specification.
6. When done, from the main checkout:
   ```bash
   soldev pipeline submit <ticket-id>
   ```
   Pushes the branch, opens a PR (or reuses an existing one for that branch), records the PR URL in the ticket's `pr:` frontmatter field, moves the ticket to `REVIEW/`, and commits the move. `REVIEW` now corresponds to a real, reviewable GitHub PR, not just a local worktree — do not push the branch or open the PR by hand.

### IN_PROGRESS → resume + implement

1. Read `worktree:` from frontmatter. If the path exists — resume there. If gone — create a fresh worktree from main.
2. Print `resuming <worktree-path>`.
3. Implement the remaining work in the worktree.
4. When done, from the main checkout: `soldev pipeline submit <ticket-id>` (see above).

### REVIEW → run review agent + process result

Fan out one subagent per ticket. Each subagent receives the worktree path, branch name, and full ticket file. Subagents run in parallel.

**Subagent output contract** — return only a JSON object, no prose, no file moves:

```json
{
  "status": "pass" | "fail",
  "summary": "one-line description of what was verified or why it failed",
  "violations": [
    { "file": "path/to/file.ml", "line": 42, "message": "description" }
  ]
}
```

Each subagent runs:

#### A. Build
```bash
cd <worktree-path>
eval $(opam env) && dune build 2>&1
```
Build failure → immediate **fail** with compiler error as violation.

#### B. Diff scope
```bash
git diff main...<branch> --stat
git diff main...<branch>
```
Verify changes are confined to files relevant to the ticket. `project/tickets/` must not be touched in the worktree branch.

#### C. Implementation correctness
Read each changed file. Verify:
- Implementation matches the ticket's **Remediation**
- No unchecked `Sys.command` return codes where failure matters
- No shell injection surface (interpolated paths use `Filename.quote`)
- New CLI commands registered in `main.ml` and listed in `bin/dune`
- New commands follow the existing `Cmdliner` pattern

#### D. Sol conventions
- No `wrapped true` libraries
- Generated README templates use `sol` commands only
- Security fields present on any new Kafka config

#### E. Docs
- Ticket-required doc changes are present
- New `sol <command>` appears in at least one user-facing doc

After collecting each result, write it to a temp file and call:

```bash
soldev pipeline review <ticket-id> --result-file /tmp/<ticket-id>-result.json
```

`soldev pipeline review` handles all ticket file moves. Do not move ticket files directly.

## Step 3 — Report

```
FEAT-002  IN_PROGRESS  → resumed ../sol-FEAT-002-perf-baseline-merge
EXP-005   REVIEW       → READY_TO_MERGE   build ✓  diff scoped
EXP-007   REVIEW       → READY_FOR_ENGINEERING   cmd_dev.ml:142 — Sys.command rc unchecked
EXP-008   REVIEW       → READY_TO_MERGE   build ✓  all checks passed
FEAT-001  READY_TO_MERGE  skipped (already past review)
```

Human next steps for tickets that reached READY_TO_MERGE:
- Run `soldev pipeline merge` (optionally with a ticket ID, or `--dry-run` first). This merges each ticket's PR via `gh pr merge --squash --delete-branch` — real GitHub branch protection and required checks gate the merge, so a ticket with a red/pending check or missing approval is left in `READY_TO_MERGE` with an error, not force-merged. On success it fast-forwards local `main`, runs the perf suite, and moves the ticket to `DONE` (or `BLOCKED_BY_PERFORMANCE` on a regression, reverting the squash commit). It does **not** push `main` — push it yourself once you're happy with the resulting local commits.
