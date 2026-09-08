---
id: DOCS-003
type: docs-finding
severity: low
source: project/audits/2026-06-22_docs_audit.md
branch: DOCS-003/scaffold-file-count
worktree: ../sun-DOCS-003-scaffold-file-count
---

Scaffold file count is 26 everywhere but actual output is 27 files

**Description:** `docs/guides/TUTORIAL.md` line 133 says "This generates 26 files." The scaffold tree listed in the Tutorial omits `events/payments/sun.toml`. The CLI success message in `cli/sun/lib/sun_cli_cmd_new.ml` line 110 also prints "Done. 26 files generated." The actual scaffold writes 27 files: the 26 listed plus `events/payments/sun.toml` (written at line 73–75 of `sun_cli_cmd_new.ml`).

**Impact:** The off-by-one count is a minor credibility gap. More importantly, the omitted `events/payments/sun.toml` from the Tutorial's scaffold tree means users don't know this file is generated or what it's for (it carries the Kafka topic name for topic auto-provisioning).

**Remediation:** Add `events/payments/sun.toml` to the scaffold tree in the Tutorial, update the file count to 27, and update the CLI success message to "Done. 27 files generated."

## Review — automated checks passed
All three changes land correctly: TUTORIAL.md updated to 27 files with events/payments/sun.toml in the scaffold tree, CLI success message updated to 27, and 27 write calls confirmed in new_workspace; project/tickets/ untouched; build clean.
