---
name: scaffold-audit
description: Run a scaffold quality audit of Sol. Verifies every sol new template compiles, preserves domain ownership, uses framework lifecycles, keeps security defaults, and gives AI agents a predictable working surface. Files actionable findings as ordinary GitHub Issues.
---

# /scaffold-audit — Scaffold Quality Audit


The core question: *does `sol new ...` generate code we would be comfortable making the default pattern for every startup using Sol?*

## Finding identity

Use descriptive GitHub Issue titles. Historical issue-number sequences are retired and do not need to continue.

## Steps

### 1. Read the template

Read `internal/pipeline/audits/SCAFFOLD_AUDIT.md` in full before starting.

### 2. Check previous findings


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

read it before filing; the report-shaped content below becomes the issue body:

- the observation and the exact command or line that shows it
- the mechanism, and what the product actually does
- what it would take to fix, and what would make a fix fail (the acceptance criteria)

### File actionable findings

For each distinct actionable finding not already represented by a GitHub Issue, create an ordinary issue with the problem, evidence, affected files, desired end state, and acceptance criteria. Prefer one coherent issue per ownership/refactor boundary over line-level findings.
