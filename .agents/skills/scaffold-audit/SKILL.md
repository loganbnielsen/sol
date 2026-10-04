---
name: scaffold-audit
description: Run a scaffold quality audit of Sol. Verifies every sol new template compiles, preserves domain ownership, uses framework lifecycles, keeps security defaults, and gives AI agents a predictable working surface. Files each finding it makes as a ticket in internal/pipeline/tickets/READY_FOR_ENGINEERING/.
---

# /scaffold-audit — Scaffold Quality Audit

Works through every section of `internal/pipeline/audits/SCAFFOLD_AUDIT.md`. Files each finding it makes as a ticket in `internal/pipeline/tickets/READY_FOR_ENGINEERING/`.

The core question: *does `sol new ...` generate code we would be comfortable making the default pattern for every startup using Sol?*

## Ticket IDs

Use `SCAFFOLD-NNN`, continuing from the highest existing `SCAFFOLD-*` ID across `internal/pipeline/audits/` and all `internal/pipeline/tickets/` subdirectories.

## Steps

### 1. Read the template

Read `internal/pipeline/audits/SCAFFOLD_AUDIT.md` in full before starting.

### 2. Check previous findings

Check all `internal/pipeline/tickets/` subdirectories for existing `SCAFFOLD-*` ticket files. Do not re-materialise a finding already tracked anywhere — but before trusting a `DONE/` ticket, run `soldev pipeline check-reverts` and treat anything it flags as still-open (see EXP-032: a merge can be reverted after the fact and never refixed, leaving the ticket falsely marked resolved).

### 3. Inspect scaffold implementation

- Read `cli/bin/cmd_new.ml`
- Read `cli/lib/base/sol_cli_scaffold.ml`
- Read `cli/lib/workspace/sol_cli_workspace.ml`
- Identify every template and generated file path for workspace, svc, worker, fn, and event scaffolds

### 4. Generate fresh scaffolds

Use a clean temporary directory and run the executable runbook from `internal/pipeline/audits/SCAFFOLD_AUDIT.md` where practical:

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

### 5. File the findings

An audit keeps no report of its own. The ticket tree is the record of every previous pass, so
read it before filing; the report-shaped content below becomes the ticket body:

- the observation and the exact command or line that shows it
- the mechanism, and what the product actually does
- what it would take to fix, and what would make a fix fail (the acceptance criteria)
- the next free `<FAMILY>-NNN`, continuing from the highest id across `internal/pipeline/tickets/`

### 7. Materialise tickets

For each open finding not already tracked, create `internal/pipeline/tickets/READY_FOR_ENGINEERING/<id>.md`:

```markdown
---
id: <SCAFFOLD-NNN>
type: scaffold-finding
severity: <critical|high|medium|low>
source: the pass that found this, by date
---

<one-line title>

**Description:** <from finding>

**Impact:** <from finding>

**Remediation:** <from finding>
```

Do not set `branch:` or `worktree:`.
