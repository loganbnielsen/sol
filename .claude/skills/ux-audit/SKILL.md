---
description: Run a developer experience audit of Sol. Verifies that a startup engineer can start a project, develop locally, and deploy to the cloud using only Sol's documented commands — without DevOps knowledge. Produces a dated report in pipeline/audits/ and materialises open findings as ticket files in pipeline/tickets/READY_FOR_ENGINEERING/.
---

# /ux-audit — Developer Experience Audit

Works through every stage of `docs/audits/UX_AUDIT.md` as if you are a startup engineer encountering Sol for the first time. Each stage has two gates: a **docs gate** (does the guide exist and is it accurate?) and a **reproduction gate** (do the commands actually work?). Writes a completed report to `pipeline/audits/<YYYY-MM-DD>_ux_audit.md` and materialises each open finding as a ticket in `pipeline/tickets/READY_FOR_ENGINEERING/`.

The core question for every check: *would a startup engineer need knowledge outside this repo to get past this step?* If yes, that is a finding.

Also check whether the experience teaches and preserves Sol's mission: autonomous domain teams, typed event contracts, generated infrastructure, explicit auth, day-2 operations through Sol commands, and AI-agent-friendly structure.

## Ticket directory structure

```
pipeline/tickets/
  BACKLOG/                  ← captured but not yet ready to act on
  READY_FOR_ENGINEERING/    ← actionable; this is where new findings land
  IN_PROGRESS/              ← worktree exists, work underway
  REVIEW/                   ← work submitted; awaiting /review-worktree
  READY_TO_MERGE/           ← review passed; human merges
  BLOCKED_BY_PERFORMANCE/   ← perf regression; needs fix or sign-off
  DONE/                     ← merged
```

## Steps

### 1. Read the template
Read `docs/audits/UX_AUDIT.md` in full before starting.

### 2. Check previous findings
Read the most recent `pipeline/audits/*_ux_audit.md` report. Note which findings were already open — verify whether they are now resolved before logging them again.

Check all `pipeline/tickets/` subdirectories for existing EXP-* ticket files. A finding already tracked anywhere in `pipeline/tickets/` (regardless of directory) should not be re-materialised. If a finding exists in `DONE/`, mark it resolved in the report — but verify the fix is still actually live in `main` before trusting that (see EXP-032: a `DONE` ticket's merge can be reverted after the fact and never refixed, leaving the ticket falsely marked resolved). Run `soldev pipeline check-reverts` and treat anything it flags as still-open, not resolved.

### 3. Work through each stage

**Stage 1 — Installation:**
- Check `README.md` for a single-command install path
- Check whether the install method works without a language toolchain already installed
- Note any prerequisites listed and whether they are reasonable for a startup engineer

**Stage 2 — Project Creation:**
- Read `README.md` for `sol new workspace` instructions
- Read `cli/sol/bin/cmd_new.ml` — count the generated files, verify library names are workspace-namespaced
- Check whether the generated README explains the project layout clearly enough without prior Sol knowledge

**Stage 3 — Local Development:**
- Check `README.md` or a linked guide for `sol dev up` and `sol dev run` instructions
- Check whether `sol dev run` exists as a command
- Verify the guide explains how to observe the message flow end-to-end (Grafana URL, what to query)

**Stage 4 — Cloud Setup:**
- Check `README.md` or a linked guide for `sol cloud init` instructions
- Check whether `sol cloud init` exists as a command
- Check `cli/platform/infra/` — verify Terraform modules exist for at least one cloud provider

**Stage 5 — First Deploy:**
- Check `README.md` or a linked guide for `sol deploy` instructions with the required target positional (`<env>/<provider>/<region>`) and all required flags
- Verify `sol deploy <target>` exists and works end-to-end
- Check whether the command prints the deployed service URL on completion

**Stage 6 — Shipping a Change:**
- Check whether the guide describes the change → deploy cycle in Sol commands only
- Check whether `sol rollback` exists

**Stage 7 — Day-2 Operations:**
- Check `README.md` for `sol logs`, `sol migrate`, `sol status` instructions
- Check whether `sol logs <service>` exists as a command
- Verify `sol new svc` / `sol new worker` / `sol new fn` are documented

**Stage 8 — Adding a Domain Event Flow:**
- Check whether the docs show `sol new event <domain>/<name>` and a worker consuming that contract
- Verify the generated event lives under `events/<domain>/`
- Verify consumers import event contract modules rather than producer service modules
- Verify schema compatibility is checked by a documented Sol command or generated test path
- Verify the new workflow does not require hand-editing Kafka or Kubernetes manifests

**Stage 9 — AI-Agent-Assisted Change:**
- Inspect generated workspace docs and templates for predictable edit points
- Verify service handlers, worker handlers, event contracts, migrations, and entrypoints are easy to locate
- Check whether framework-owned concerns are separated from business logic
- If reproducing the stage, make a narrow business change and verify it compiles using documented Sol commands only

### 4. Write the report

Create `pipeline/audits/<YYYY-MM-DD>_ux_audit.md` with:
- A header showing the date
- Each stage with `[x]` / `[ ]` for the docs gate and reproduction gate separately
- A Findings section with one entry per gap using the format from `docs/audits/UX_AUDIT.md`
- A summary table

Use finding IDs prefixed `EXP-` continuing from the highest ID across all existing `pipeline/tickets/` files and previous reports.

### 5. Materialise tickets

For each finding with `Status: Open` in the report:

1. Search all `pipeline/tickets/` subdirectories for `<id>.md`. If found anywhere, skip.
2. If not found, create `pipeline/tickets/READY_FOR_ENGINEERING/<id>.md`:

```markdown
---
id: <EXP-NNN>
type: ux-finding
severity: <blocker|high|medium|low>
source: pipeline/audits/<YYYY-MM-DD>_ux_audit.md
---

<one-line title>

**Description:** <from finding>

**Impact:** <from finding>

**Remediation:** <from finding>
```

Do not set `branch:` or `worktree:` — those are written by `/start` when work begins.
