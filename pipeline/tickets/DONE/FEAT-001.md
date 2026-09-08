---
id: FEAT-001
type: feature
severity: medium
source: internal
branch: FEAT-001/sundev-binary
worktree: ../sun-FEAT-001-sundev-binary
---

Split `sun pipeline` into a separate `sundev` binary.

**Problem:** The `sun` binary ships to end users of the Sun platform, but `sun pipeline` (ls/merge/review) is internal tooling for developing Sun itself. They operate on different directory conventions — workspace commands expect `app/`, pipeline commands expect `hygiene/tickets/` — and have no business in the same binary.

**Remediation:**

1. Create `cli/sundev/bin/` with its own `dune` and `main.ml` that registers only the pipeline commands.
2. Move `cmd_pipeline.ml` from `cli/sun/bin/` to `cli/sundev/bin/` (or into a shared lib if needed).
3. Remove `Cmd_pipeline.cmd` from `cli/sun/bin/main.ml` and drop `yojson` from its `dune` if no longer needed.
4. Update the `~/.local/bin/sundev` symlink in the install instructions (the `sun` symlink stays as-is).
5. Update any skill or doc references from `sun pipeline` to `sundev pipeline`.

**Outcome:** `sun` contains only workspace commands (`new`, `dev`, `up`, `deploy`, `status`, `migrate`, `logs`, `rollback`). `sundev` contains internal pipeline tooling (`ls`, `merge`, `review`). A user who installs Sun never sees pipeline commands.

## Review — returned for revision
- `.claude/skills/review-worktree/SKILL.md:80` — Section heading still reads '### 3. Process results via sun pipeline review' — should be 'sundev pipeline review' to match the rest of the file
- `.claude/CLAUDE.md:33` — Still references 'sun pipeline review handles file moves' — should be updated to 'sundev pipeline review'
- `README.md` — Remediation item 4 requires updating install instructions for ~/.local/bin/sundev symlink, but README.md contains no mention of sundev or a sundev symlink install step

## Review — automated checks passed
All 5 remediation items present: sundev binary created, cmd_pipeline.ml moved, sun binary cleaned up, README updated with symlink, all doc references updated from sun pipeline to sundev pipeline.
