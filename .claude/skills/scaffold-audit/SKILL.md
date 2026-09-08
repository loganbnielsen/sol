---
description: Run a scaffold quality audit of Sol. Verifies every sol new template compiles, preserves domain ownership, uses framework lifecycles, keeps security defaults, and gives AI agents a predictable working surface. Produces a dated report in pipeline/audits/ and materialises open findings as ticket files in pipeline/tickets/READY_FOR_ENGINEERING/.
---

# /scaffold-audit — Scaffold Quality Audit

Works through every section of `docs/audits/SCAFFOLD_AUDIT.md`. Writes a completed report to `pipeline/audits/<YYYY-MM-DD>_scaffold_audit.md` and materialises each open finding as a ticket in `pipeline/tickets/READY_FOR_ENGINEERING/`.

The core question: *does `sol new ...` generate code we would be comfortable making the default pattern for every startup using Sol?*

## Ticket IDs

Use `SCAFFOLD-NNN`, continuing from the highest existing `SCAFFOLD-*` ID across `pipeline/audits/` and all `pipeline/tickets/` subdirectories.

## Steps

### 1. Read the template

Read `docs/audits/SCAFFOLD_AUDIT.md` in full before starting.

### 2. Check previous findings

Read the most recent `pipeline/audits/*_scaffold_audit.md` report if one exists. Check all `pipeline/tickets/` subdirectories for existing `SCAFFOLD-*` ticket files. Do not re-materialise a finding already tracked anywhere — but before trusting a `DONE/` ticket, run `soldev pipeline check-reverts` and treat anything it flags as still-open (see EXP-032: a merge can be reverted after the fact and never refixed, leaving the ticket falsely marked resolved).

### 3. Inspect scaffold implementation

- Read `cli/sol/bin/cmd_new.ml`
- Read `cli/sol/lib/sol_cli_scaffold.ml`
- Read `cli/sol/lib/sol_cli_workspace.ml`
- Identify every template and generated file path for workspace, svc, worker, fn, and event scaffolds

### 4. Generate fresh scaffolds

Use a clean temporary directory and run the executable runbook from `docs/audits/SCAFFOLD_AUDIT.md` where practical:

```bash
sol new workspace scaffold_audit
cd scaffold_audit
eval $(opam env) && dune build
sol new svc payments/refund
sol new worker logistics/fulfillment
sol new fn billing/invoice
sol new event billing/payment_confirmed
eval $(opam env) && dune build
```

If a command cannot be run because dependencies or local infrastructure are unavailable, inspect the template source and record the reproduction gap separately.

### 5. Verify generated semantics

- Check service templates use `Sol.Service.Make` and explicit route auth
- Check worker templates use `Sol.Worker.Make`, import event contracts, and call `ack()` only after side effects
- Check function templates use `Sol.Fn.Make` and return result values
- Check event templates live under `events/<domain>/` and satisfy the message contract
- Check generated docs avoid stale commands and repo-local scripts
- Check `sol.toml`, Dockerfile, and deployment metadata preserve Sol defaults

### 6. Write the report

Create `pipeline/audits/<YYYY-MM-DD>_scaffold_audit.md` with:
- A header showing the date and previous-finding status changes
- Each section with `[x]` / `[ ]` checklist results
- A Findings section with `Status: Open` or `Status: Resolved`
- A summary table

### 7. Materialise tickets

For each open finding not already tracked, create `pipeline/tickets/READY_FOR_ENGINEERING/<id>.md`:

```markdown
---
id: <SCAFFOLD-NNN>
type: scaffold-finding
severity: <critical|high|medium|low>
source: pipeline/audits/<YYYY-MM-DD>_scaffold_audit.md
---

<one-line title>

**Description:** <from finding>

**Impact:** <from finding>

**Remediation:** <from finding>
```

Do not set `branch:` or `worktree:`.
