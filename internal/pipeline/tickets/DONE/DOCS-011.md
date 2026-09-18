---
id: DOCS-011
type: docs-finding
severity: low
source: pipeline/audits/2026-09-08_docs_audit.md
---

`sol open` is a real registered command, undocumented anywhere

**Description:** `sol open` (opens Grafana logs/metrics/dashboard views in a browser, with `--scope`/`--observability-backend`/`--base-domain` flags) is registered in `cli/sol/bin/main.ml`'s command group alongside every other top-level command, but `README.md`, `docs/guides/TUTORIAL.md`, and `docs/planning/ROADMAP.md` have zero mentions of it while every other command has TUTORIAL.md coverage.

**Impact:** A real, working day-2-operations command is invisible to anyone reading the docs — they'd have to already know it exists (e.g. from `sol --help`) to use it.

**Remediation:** Add `sol open` to `docs/guides/TUTORIAL.md`'s CLI reference alongside `sol logs`/`sol status`, documenting its scope options and what it opens.
