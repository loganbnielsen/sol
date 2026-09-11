---
id: CODEX_STYLE_AUDIT-050
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-050/structured-workspace-scan
worktree: ../sun-CODEX_STYLE_AUDIT-050-structured-workspace-scan
---

Replace workspace scan source-text parsing with structured discovery.

**Depends on:** CODEX_STYLE_AUDIT-040.

**Problem:** `cli/sun/lib/sun_cli_workspace_scan.ml:37-76` scans OCaml source
text for `let topic_name = "..."`. `Sun_cli_manifest_yaml.extract_schedule`
similarly scans source text for `schedule = "..."`. These are brittle string
parsers over OCaml code.

**Goal:** Move discovery to structured metadata or a parser that understands the
source format.

**Acceptance criteria:**

- Stop using ad hoc substring scans for topics and schedules.
- Prefer `sun.toml`, generated metadata, or a real OCaml parser/AST if source
  inspection remains required.
- Add tests showing comments or unrelated strings do not create false positives.

## Review — automated checks passed
Build succeeds, all tests pass (including new false-positive and extract_schedule tests), discover_topics reads only sun.toml files, extract_schedule reads only sun.toml, scaffold templates emit sun.toml for both -fn and event directories, no wrapped true, no new Kafka config, and project/tickets/ is untouched in the worktree branch.
