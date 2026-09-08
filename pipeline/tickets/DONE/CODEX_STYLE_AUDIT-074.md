---
id: CODEX_STYLE_AUDIT-074
type: refactor
severity: medium
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-074/contributing-map
worktree: /home/lbendtly/Code/sun-CODEX-074
---

Create a contributor map for ownership boundaries and extension points.

**Depends on:** none.

**Problem:** New contributors have to infer ownership boundaries from directory
layout and existing code: framework primitives, integrations, CLI commands,
deployment compiler, generated templates, platform infra, hosted model, and
ticket workflow. This makes it hard to know where to implement changes without
creating cross-cutting drift.

**Goal:** Give open-source contributors a concise map of where intent lives and
where to extend each concern.

**Acceptance criteria:**

- Add or update `CONTRIBUTING.md` or `docs/architecture/contributing-map.md`.
- Include sections for command changes, deployment behavior, manifest rendering,
  scaffold templates, integrations, tests, and docs.
- Link to `/style-audit`, `/audit`, `/scaffold-audit`, and `/e2e` workflows.
- Include "do not" guidance for common mistakes such as adding raw shell
  commands, bypassing deployment plans, or editing generated YAML paths directly.

## Review — automated checks passed
The revised contributor map satisfies the acceptance criteria: it lives in docs/architecture/contributing-map.md, includes all requested ownership sections, links audit/e2e entry points to tracked files, documents the /style-audit caveat against stable tracked project/tickets/, and includes required do-not guidance for raw shell commands, bypassing deployment plans, and direct generated YAML edits. Docs verification and dune build passed.
