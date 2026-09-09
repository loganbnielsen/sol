---
description: Review open ticket PRs and decide if they're ready to merge. Fans out one subagent per PR, checks the diff and build against ticket intent. Subagents emit structured JSON; soldev pipeline review leaves the verdict on the PR itself.
---

# /review-worktree — Review ticket PRs for merge readiness

Automated review gate. Discovers tickets in `READY_FOR_ENGINEERING/` that already have an open PR (via `soldev pipeline ls`), fans out one subagent per worktree, collects structured JSON results, and delegates the verdict to `soldev pipeline review` — which leaves it on the PR (a real GitHub approval on pass, a comment on fail), not on any ticket file.

## Usage

```
/review-worktree                    # review every READY_FOR_ENGINEERING ticket with an open PR
/review-worktree EXP-005            # review one specific ticket
/review-worktree all                # explicit alias for the above
```

## Steps

### 1. Discover tickets to review

Run `soldev pipeline ls` and select `READY_FOR_ENGINEERING` tickets annotated `(PR #N open)`. Confirm each has a live worktree (`git worktree list`); if the worktree is gone, re-create it from the PR's branch first. If specific IDs were passed, filter to those (error if a named ticket has no open PR). `all` selects every eligible ticket.

### 2. Fan out one subagent per worktree

Spawn all review agents in parallel. Each agent receives the worktree path, branch name, PR URL, and full ticket file content (description + remediation = ground truth for intent — read it from the branch's own `pipeline/tickets/DONE/<id>.md`, since the worker's own commit already moved it there).

**Subagent output contract:** each agent must return **only** a JSON object to stdout matching this schema — no prose, no file operations, no ticket moves:

```json
{
  "status": "pass" | "fail",
  "summary": "one-line description of what was verified or why it failed",
  "violations": [
    { "file": "path/to/file.ml", "line": 42, "message": "description" }
  ]
}
```

- `violations` is an empty array on pass.
- `line` may be `null` for violations without a specific line (e.g. missing doc, missing registration).
- `summary` is always required.

Each agent runs:

#### A. Build
```bash
cd <worktree-path>
eval $(opam env) && dune build 2>&1
```
A build failure is an immediate **fail** — stop and emit JSON with the compiler error as the violation message.

#### B. Diff scope
```bash
git diff main...<branch> --stat
git diff main...<branch>
```
Verify:
- Changes are confined to files relevant to the ticket
- No unrelated files modified (stray reformatting, debug lines, etc.)
- The **only** `pipeline/tickets/` change is the expected `READY_FOR_ENGINEERING/<id>.md → DONE/<id>.md` move — that one is required, not a scope violation; anything else there is.

#### C. Implementation correctness

Read each changed file in full. Verify:
- Implementation matches the ticket's **Remediation**
- No unchecked `Sys.command` return codes where failure matters
- No new shell injection surface (interpolated paths must use `Filename.quote`)
- New CLI commands registered in `main.ml` and listed in `bin/dune`
- New commands follow the existing `Cmdliner` pattern (term → cmd → group)

#### D. Sol conventions
- No `wrapped true` libraries introduced
- Generated README templates use `sol` commands only — no `dune exec` or `bash` scripts
- Security fields present on any new Kafka config

#### E. Docs
- If the ticket requires a doc change, verify README or TUTORIAL was updated
- If a new `sol <command>` was added, it appears in at least one user-facing doc

### 3. Process results via soldev pipeline review

For each subagent result, write the JSON to a temp file and call:

```bash
soldev pipeline review <ticket-id> --result-file /tmp/<ticket-id>-result.json
```

On pass, this leaves a real GitHub review approval on the PR (which `soldev pipeline merge` checks for before it will act). On fail, it leaves a plain PR comment with the violations — the branch just needs another commit, the same open PR, no ticket-directory round trip. Do **not** move or edit ticket files yourself; there is nothing on `main` for this step to touch.

### 4. Summarise

```
EXP-001  PR #41  → approved             build ✓  diff scoped  docs updated
EXP-002  PR #42  → changes requested    cmd_dev.ml:142 — Sys.command rc unchecked
EXP-005  PR #43  → approved             build ✓  ClusterIP fix verified
```

Human next steps:
- Approved PRs — run `soldev pipeline merge` to merge automatically once CI is also green
- Changes-requested PRs — pick up with `/work <ticket-id>` to push another commit to the existing branch
