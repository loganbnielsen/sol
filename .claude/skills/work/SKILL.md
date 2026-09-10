---
description: Unified ticket worker. Dispatches based on ticket state — creates worktrees for READY_FOR_ENGINEERING tickets (resuming one that already has an open PR/branch), and runs the review agent on tickets with an open PR. One command for the full development loop.
---

# /work — Unified ticket worker

Single entry point for the development loop. Pass ticket IDs, a group selector, or nothing to get a menu. Dispatches each ticket to the right action.

Since REFAC-077, there are only two persisted ticket-directory states: `READY_FOR_ENGINEERING/` and `DONE/` (plus `BACKLOG/`, a pre-work human-judgment gate this skill doesn't touch). "In progress" and "in review" are no longer local directories — they're just an open PR/branch for the ticket, which GitHub already tracks. A ticket's move to `DONE/` is committed **on its own PR branch**, as the worker's own final commit, so it rides into `main` inside the same squashed commit as the code — there is no separate commit on `main` for it.

## Usage

```
/work                        # list all active tickets; user picks
/work all                    # process every ticket in READY_FOR_ENGINEERING/
/work FEAT-002               # dispatch one ticket by ID
/work EXP-005 EXP-007        # dispatch multiple tickets
/work open                   # all tickets in READY_FOR_ENGINEERING/
/work open-exp               # all EXP-* tickets in READY_FOR_ENGINEERING/
/work open-audit             # all AUDIT-* tickets in READY_FOR_ENGINEERING/
```

## Step 1 — Resolve tickets and their states

For each ID given: look it up with `soldev pipeline check <ticket-id>` (or `find_ticket` semantics) — a ticket is either in `READY_FOR_ENGINEERING/` (not started, or already has an open PR — check with `soldev pipeline ls`, which annotates a ticket with `(PR #N open)` when one exists) or `DONE/`.

Use deterministic pipeline tooling for ticket status whenever possible:

```bash
soldev pipeline ls
```

This prints ticket state, dependency status, human-decision blockers, actionable status, and (for `READY_FOR_ENGINEERING` tickets) whether a PR is already open. It also annotates `(dirty worktree @ <path>)` and/or `(unpushed commits @ <path>)` when an existing worktree branch for the ticket has uncommitted or unpushed work — treat that as an interrupted implementation to **resume**, not as a fresh ticket. Do not reconstruct dependency graphs by interpretation when this command is available.

## Step 2 — Dispatch

### No open PR yet → create worktree + implement

Before creating a worktree, run the deterministic ticket preflight:

```bash
soldev pipeline check <ticket-id>
```

Only create a worktree if the command exits 0 and prints `status: actionable`.

If it reports `blocked-for-human-decision`, `blocked-by-dependency`, `unknown ticket`, or any non-actionable status: do not create a worktree, leave the ticket where it is, print the command output for the user.

If `soldev pipeline check <ticket-id>` prints `worktree: (dirty worktree ...)` or `(unpushed commits ...)`, stop and resume that existing worktree — do **not** create a second worktree for the same ticket.

1. Determine branch slug from ticket title (lowercase, hyphens).
2. Create worktree:
   ```bash
   git worktree add -b ticket-id/short-slug ../sol-ticket-id-short-slug main
   ```
   No `pipeline/tickets/` commit for this — nothing to record on `main` yet.
3. Implement the ticket in the worktree — read the ticket's **Remediation** as the specification.
4. **Your own last implementation commit in the worktree must move the ticket file itself:**
   ```bash
   git mv pipeline/tickets/READY_FOR_ENGINEERING/<ticket-id>.md pipeline/tickets/DONE/<ticket-id>.md
   ```
   Commit this together with (or as the final commit after) your code changes, on the branch. This is what makes the eventual squash-merge carry the ticket's completion into `main` for free.
5. From **inside the worktree** (not the main checkout — there is nothing on `main` to touch):
   ```bash
   soldev pipeline submit <ticket-id>
   ```
   Pushes the branch and opens a PR (or reuses an existing one for that branch) via `gh pr create`. Does not touch `pipeline/tickets/` on `main` at all.

### Ticket already has an open PR → resume + implement

1. Find the worktree via `git worktree list` (the branch is `<ticket-id>/...`). If gone, re-create it from the PR's branch: `git worktree add <path> <ticket-id>/<slug>` (the branch already exists on `origin`).
2. Implement the remaining work. A bounce from review just means more commits on this same branch — never a ticket-directory round trip.
3. When done: `git push` (from the worktree) to update the existing PR.

### Has an open PR, ready for review → run review agent + process result

Fan out one subagent per ticket. Each subagent receives the worktree path, branch name, PR URL, and full ticket file. Subagents run in parallel.

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
Verify changes are confined to files relevant to the ticket, **except** the expected `pipeline/tickets/READY_FOR_ENGINEERING/<id>.md → DONE/<id>.md` move — that one is required, not a scope violation.

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

`soldev pipeline review` leaves the verdict on the PR itself as a plain comment either way — one carrying the `SOLDEV-REVIEW: PASS` marker on pass (which `soldev pipeline merge` checks for before it will act), an ordinary violations comment on fail. It's a comment, not a formal GitHub review, because `gh` always runs as the PR's own author here and GitHub refuses self-approval. It does not touch any ticket file; there is nothing to move.

## Step 3 — Report

```
FEAT-002  READY_FOR_ENGINEERING  (PR #41 open)  → resumed ../sol-FEAT-002-perf-baseline-merge
EXP-005   PR #42  → approved
EXP-007   PR #43  → changes requested   cmd_dev.ml:142 — Sys.command rc unchecked
```

Human next steps for approved tickets:
- Run `soldev pipeline merge` (optionally with a ticket ID, or `--dry-run` first). This checks the PR for the review-pass marker comment and CI status directly against GitHub, and only then runs `gh pr merge --squash --delete-branch --admin` — a red/pending check or missing pass-marker leaves the PR open, untouched, not force-merged. On success it fast-forwards local `main`, runs the perf suite, and updates the baseline (or reverts the squash commit on a real regression — which un-does the ticket's `DONE` move right along with the code, landing it back in `READY_FOR_ENGINEERING` automatically). It does **not** push `main` — push it yourself once you're happy with the resulting local commits.
