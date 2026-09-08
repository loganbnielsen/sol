---
description: Review completed worktrees and decide if they're ready to merge. Fans out one subagent per worktree, checks the diff and build against ticket intent. Subagents emit structured JSON; soldev pipeline review handles all ticket file moves.
---

# /review-worktree — Review worktrees for merge readiness

Automated review gate. Reads tickets from `pipeline/tickets/REVIEW/`, fans out one subagent per worktree, collects structured JSON results, and delegates all ticket state transitions to `soldev pipeline review`.

## Usage

```
/review-worktree                    # review all tickets in REVIEW/ that have a worktree
/review-worktree EXP-005            # review one specific ticket
/review-worktree all                # explicit alias for reviewing every ticket in REVIEW/
```

## Steps

### 1. Discover tickets to review

Read `pipeline/tickets/REVIEW/*.md`. Select those where a `worktree:` path is set and that path exists on disk. If specific IDs were passed, filter to those (error if a named ticket has no live worktree). `all` selects every ticket in `REVIEW/`.

### 2. Fan out one subagent per worktree

Spawn all review agents in parallel. Each agent receives the worktree path, branch name, and full ticket file content (description + remediation = ground truth for intent).

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
- `pipeline/tickets/` was **not** touched in the worktree branch

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

`soldev pipeline review` handles all ticket file moves, appends notes, and commits the result itself. Do **not** move ticket files or append to them directly, and no separate commit is needed after calling it.

### 4. Summarise

```
EXP-001  → READY_TO_MERGE          build ✓  diff scoped  docs updated
EXP-002  → READY_FOR_ENGINEERING   cmd_dev.ml:142 — Sys.command rc unchecked
EXP-005  → READY_TO_MERGE          build ✓  ClusterIP fix verified
```

Human next steps:
- `pipeline/tickets/READY_TO_MERGE/` — run `soldev pipeline merge` to merge all branches automatically
- `pipeline/tickets/READY_FOR_ENGINEERING/` — pick up with `/work <ticket-id>` to resume in the existing worktree
