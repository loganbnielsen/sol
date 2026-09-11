---
description: Run a developer dogfood pass of Sol. Executes the golden path from sol new workspace through curl against a live service, times each step, and logs every friction point. Produces a dated report in pipeline/dogfood/ and materialises blocking findings as ticket files in pipeline/tickets/READY_FOR_ENGINEERING/.
---

# /dogfood — Golden Path Dogfood Run

Executes the full Sol developer golden path as a first-time user would, following
the runbook at `docs/dogfood/DOGFOOD.md`. Times every step, records friction, and
determines whether the two-minute deploy claim holds on a live local substrate.

Writes a completed report to `pipeline/dogfood/RUN_<YYYY-MM-DD>.md` and materialises
each blocking or high-friction finding as a ticket in
`pipeline/tickets/READY_FOR_ENGINEERING/`.

## Ticket directory structure

```
pipeline/tickets/
  BACKLOG/                  ← captured but not yet ready to act on
  READY_FOR_ENGINEERING/    ← actionable; blocking findings land here
                               (also covers "worktree/PR open" — GitHub's own
                               open-PR/review/CI state tracks that, no local
                               directory duplicates it; see REFAC-077)
  DONE/                     ← merged
```

## Steps

### 1. Read the runbook

Read `docs/dogfood/DOGFOOD.md` in full before starting.

### 2. Check previous runs

Read the most recent report in `pipeline/dogfood/` (highest date). Note which
friction items were logged — verify whether they are now resolved before logging
them again.

Check all `pipeline/tickets/` subdirectories for existing `FRIC-*` ticket files.
A finding already tracked anywhere in `pipeline/tickets/` should not be
re-materialised. If it exists in `DONE/`, mark it resolved in the report — but
verify the fix is still actually live in `main` before trusting that (see
EXP-032: a `DONE` ticket's merge can be reverted after the fact and never
refixed, leaving the ticket falsely marked resolved). Run
`soldev pipeline check-reverts` and treat anything it flags as still-open,
not resolved.

### 3. Prepare the binary

Build the current CLI from the Sol checkout and place it first on PATH:

```bash
cd <sol-checkout>
eval $(opam env)
dune build cli/sol/bin/main.exe
export SOL_HOME=$(pwd)
mkdir -p "$SOL_HOME/.dogfood-bin"
ln -sf "$SOL_HOME/_build/default/cli/sol/bin/main.exe" "$SOL_HOME/.dogfood-bin/sol"
export PATH="$SOL_HOME/.dogfood-bin:$PATH"
hash -r
```

### 4. Run the golden path

Use a fresh workspace name (e.g. `dogfood-<YYYY-MM-DD>`). Record elapsed time
for each command using `/usr/bin/time -f 'elapsed=%E'` or `date +%s%3N` before
and after.

Work through each step in order. If a step fails, record the failure in the
friction log, attempt to diagnose it, and continue with subsequent steps where
possible.

**Steps to run:**

1. `sol new workspace <name>` — scaffold
2. `cd <name> && dune build` — build generated workspace
3. `sol dev up` — provision or reconcile local substrate (k3d cluster)
4. `sol up` — build Docker images, push, deploy
5. `sol migrate --table <name>_migrations` — apply DB migrations
6. `sol status` — check pods
7. `curl http://localhost:8080/health`
8. `curl -X POST http://localhost:8080/charges -H 'Content-Type: application/json' -d '{"customer_id":"cus_dogfood","amount_cents":999,"currency":"usd"}'`
9. Wait up to 10s for worker to consume, then `curl http://localhost:8080/notifications`

For step 9: verify the notification row was written by `notify_worker` consuming
a Kafka event, not directly inserted by the HTTP service. If the row is present,
the Kafka path is proven.

### 5. Evaluate the two-minute claim

After step 4 (`sol up`), measure the wall-clock time from `sol new workspace`
through first successful `curl /health`. Does it stay under two minutes on an
existing substrate?

Note: `sol dev up` on a fresh cluster takes ~5 min and is substrate
bootstrap — it does not count against the two-minute claim.

### 6. Write the report

Create `pipeline/dogfood/RUN_<YYYY-MM-DD>.md` using the template from
`docs/dogfood/DOGFOOD.md`. Fill in:

- Tool versions actually observed
- Timing for every step
- Whether the flow completed without manual intervention
- Friction log entries for every step that required knowledge outside the
  command output or docs, produced a confusing message, or failed
- Findings section for non-obvious correctness or UX observations
- List of any tickets filed

### 7. Materialise tickets

For each friction log entry where **Blocks two-minute claim? yes**, or any
correctness finding that would prevent a user from completing the flow:

1. Search all `pipeline/tickets/` subdirectories for `FRIC-NNN`. If found, skip.
2. If not found, create `pipeline/tickets/READY_FOR_ENGINEERING/FRIC-NNN.md`:

```markdown
---
id: FRIC-NNN
type: dogfood-finding
severity: <blocker|high|medium|low>
source: pipeline/dogfood/RUN_<YYYY-MM-DD>.md
---

**Depends on:** None.

<one-line title>

**Description:** <what happened>

**Impact:** <what a first-time user would experience>

**Remediation:** <specific, actionable fix>
```

Assign FRIC IDs starting from one above the highest existing `FRIC-*` ID across
all `pipeline/tickets/` subdirectories. If none exist, start at `FRIC-001`.

Medium and low friction items that do not block the flow go in the report only —
do not create tickets for them unless they recur across multiple runs.

Do not set `branch:` or `worktree:` — those are written by `/work` when
implementation begins.
