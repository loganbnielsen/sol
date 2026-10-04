---
name: docs-audit
description: Run a documentation truth audit of Sol. Verifies README, tutorial, roadmap, generated docs, package specs, and documented CLI commands against implementation reality. Files each finding it makes as a ticket in internal/pipeline/tickets/READY_FOR_ENGINEERING/.
---

# /docs-audit — Documentation Truth Audit

Works through every section of `internal/pipeline/audits/DOCS_AUDIT.md`. Files each finding it makes as a ticket in `internal/pipeline/tickets/READY_FOR_ENGINEERING/`.

The core question: *can a startup engineer trust this documentation as the truth without reading source code or old work summaries?*

## Ticket IDs

Use `DOCS-NNN`, continuing from the highest existing `DOCS-*` ID across `internal/pipeline/audits/` and all `internal/pipeline/tickets/` subdirectories.

## Steps

### 1. Read the template

Read `internal/pipeline/audits/DOCS_AUDIT.md` in full before starting.

### 2. Check previous findings

Check all `internal/pipeline/tickets/` subdirectories for existing `DOCS-*` ticket files. Do not re-materialise a finding already tracked anywhere — but before trusting a `DONE/` ticket, run `soldev pipeline check-reverts` and treat anything it flags as still-open (see EXP-032: a merge can be reverted after the fact and never refixed, leaving the ticket falsely marked resolved).

### 3. Verify source-of-truth docs

- Read `README.md`, `docs/ROADMAP.md`, and `docs/guides/TUTORIAL.md`
- Check whether status claims match implementation and tests
- Identify historical sections that could be mistaken for current product state
- Compare product framing and terminology across docs

### 4. Verify documented commands

- Read `cli/bin/main.ml` and `cli/bin/cmd_*.ml`
- Build a list of registered commands and flags
- Compare against every documented `sol ...` command in root docs and generated README templates
- Verify documented output promises by reading implementation or running commands where practical

### 5. Verify quickstart and generated docs

- Read generated README templates in `cli/bin/cmd_new.ml`
- Check quickstart commands, ports, health paths, curl examples, Grafana queries, and working directories
- Confirm normal workflows use Sol commands first and do not require repo-local bash scripts

### 6. Verify package specs

- for each package-level `*.md` under `framework/`, compare public API claims against nearby `.mli` files
- Mark deferred or speculative claims as findings if they are not clearly labeled

### 5. File the findings

An audit keeps no report of its own. The ticket tree is the record of every previous pass, so
read it before filing; the report-shaped content below becomes the ticket body:

- the observation and the exact command or line that shows it
- the mechanism, and what the product actually does
- what it would take to fix, and what would make a fix fail (the acceptance criteria)
- the next free `<FAMILY>-NNN`, continuing from the highest id across `internal/pipeline/tickets/`

### 8. Materialise tickets

For each open finding not already tracked, create `internal/pipeline/tickets/READY_FOR_ENGINEERING/<id>.md`:

```markdown
---
id: <DOCS-NNN>
type: docs-finding
severity: <critical|high|medium|low>
source: the pass that found this, by date
---

<one-line title>

**Description:** <from finding>

**Impact:** <from finding>

**Remediation:** <from finding>
```

Do not set `branch:` or `worktree:`.
