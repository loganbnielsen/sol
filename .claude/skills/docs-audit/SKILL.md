---
description: Run a documentation truth audit of Sol. Verifies README, tutorial, roadmap, generated docs, package specs, and documented CLI commands against implementation reality. Produces a dated report in project/audits/ and materialises open findings as ticket files in project/tickets/READY_FOR_ENGINEERING/.
---

# /docs-audit — Documentation Truth Audit

Works through every section of `docs/audits/DOCS_AUDIT.md`. Writes a completed report to `project/audits/<YYYY-MM-DD>_docs_audit.md` and materialises each open finding as a ticket in `project/tickets/READY_FOR_ENGINEERING/`.

The core question: *can a startup engineer trust this documentation as the truth without reading source code or old work summaries?*

## Ticket IDs

Use `DOCS-NNN`, continuing from the highest existing `DOCS-*` ID across `project/audits/` and all `project/tickets/` subdirectories.

## Steps

### 1. Read the template

Read `docs/audits/DOCS_AUDIT.md` in full before starting.

### 2. Check previous findings

Read the most recent `project/audits/*_docs_audit.md` report if one exists. Check all `project/tickets/` subdirectories for existing `DOCS-*` ticket files. Do not re-materialise a finding already tracked anywhere.

### 3. Verify source-of-truth docs

- Read `README.md`, `docs/planning/ROADMAP.md`, `docs/guides/TUTORIAL.md`, and `docs/planning/WORK_SUMMARY.md`
- Check whether status claims match implementation and tests
- Identify historical sections that could be mistaken for current product state
- Compare product framing and terminology across docs

### 4. Verify documented commands

- Read `cli/sol/bin/main.ml` and `cli/sol/bin/cmd_*.ml`
- Build a list of registered commands and flags
- Compare against every documented `sol ...` command in root docs and generated README templates
- Verify documented output promises by reading implementation or running commands where practical

### 5. Verify quickstart and generated docs

- Read generated README templates in `cli/sol/bin/cmd_new.ml`
- Check quickstart commands, ports, health paths, curl examples, Grafana queries, and working directories
- Confirm normal workflows use Sol commands first and do not require repo-local bash scripts

### 6. Verify package specs

- For each package-level `*.md` under `integrations/kafka/` and `framework/`, compare public API claims against nearby `.mli` files
- Mark deferred or speculative claims as findings if they are not clearly labeled

### 7. Write the report

Create `project/audits/<YYYY-MM-DD>_docs_audit.md` with:
- A header showing the date and previous-finding status changes
- Each section with `[x]` / `[ ]` checklist results
- A Findings section with `Status: Open` or `Status: Resolved`
- A summary table

### 8. Materialise tickets

For each open finding not already tracked, create `project/tickets/READY_FOR_ENGINEERING/<id>.md`:

```markdown
---
id: <DOCS-NNN>
type: docs-finding
severity: <critical|high|medium|low>
source: project/audits/<YYYY-MM-DD>_docs_audit.md
---

<one-line title>

**Description:** <from finding>

**Impact:** <from finding>

**Remediation:** <from finding>
```

Do not set `branch:` or `worktree:`.
