---
name: agent-setup
description: Consolidate this repo's agent surface into tool-neutral defaults — skills in `.agents/skills/<name>/SKILL.md` and durable context in the repo-root `AGENTS.md` — migrating away from tool-specific roots (Claude Code's `.claude/`, Codex's `.codex/`) and removing the duplicates. Use when setting up or cleaning up agent files, migrating skills between agent tools, de-duplicating `.claude`/`.codex`, or when asked to "set up the agent files", "move everything to .agents", or "clean up the agent directories".
---

# Agent Setup

One capability: make the agent surface **tool-neutral**. Every agent skill lives
in one place, and the durable context lives in one file, regardless of which CLI
is driving.

## Target layout

```
.agents/skills/<name>/SKILL.md     ← project skills (interoperable default)
AGENTS.md                          ← project context (was CLAUDE.md)
~/.agents/skills/<name>/SKILL.md   ← user-level skills
```

Discovery roots, in priority order (highest first), for reference:

1. `./.deepcode/skills/<folder>/SKILL.md`   (DeepCode-native — avoid, tool-specific)
2. `./.agents/skills/<folder>/SKILL.md`     (interoperable — **the default**)
3. `~/.deepcode/skills/<folder>/SKILL.md`
4. `~/.agents/skills/<folder>/SKILL.md`

Prefer `.agents/`: other tools that support the Agent Skills standard read it, so
the repo carries one copy instead of one per vendor. Only use a vendor-native
root when a tool cannot read `.agents/`.

## Procedure

1. **Inventory** every root that exists: `.claude/skills/*`, `.claude/CLAUDE.md`,
   `.codex/` (repo or `~/.codex/`), `.agents/`, `.deepcode/`, `AGENTS.md`,
   `CLAUDE.md`. List them before moving anything; do not assume a directory
   exists (`.codex` frequently does not).

2. **Back up anything you will delete.** User-level roots hold more than skills —
   credentials, session history, caches:
   ```sh
   ts="$(date -u +%Y%m%dT%H%M%SZ)"
   tar czf ~/agent-cleanup-backup-$ts.tar.gz -C ~ .claude .claude.json .codex 2>/dev/null || true
   ```
   A repo root is covered by git; a user-level root is not. Never delete a
   user-level root until the tarball exists and you have named what is in it.

3. **Migrate skills** (project and user scope separately — never move a skill
   between scopes):
   - Copy each `<skill>/` directory whole (`SKILL.md` plus any `references/`,
     `scripts/`, `templates/`, assets).
   - Remove the vendor's *bundled/system* skills (e.g. `.codex/skills/.system/`)
     from the migration list — they are the vendor's, not the repo's.
   - If the destination exists, stop and report the conflict; do not merge.

4. **Migrate context**: `CLAUDE.md` / `.claude/CLAUDE.md` → the repo-root
   `AGENTS.md`. Keep the body; adjust only references to the old filename.

5. **Remove the now-duplicate tool roots** (repo: commit the deletion; user: after
   the backup). Report exactly what was removed.

6. **Validate**: every `SKILL.md` has valid frontmatter with `name` equal to its
   folder, and `description` present and under 1024 chars. Then run `/skills` in
   the CLI to confirm discovery.

## Frontmatter rule (the common defect)

Tool-native skills often carry **only** `description:`. The Agent Skills spec
requires `name` too, and it must equal the directory name:

```yaml
---
name: agent-setup              # == the folder name, lowercase/hyphens, ≤64 chars
description: <what it does>. Use when <triggers>.
---
```

When migrating, insert a missing `name:` as the first frontmatter key; the folder
name is the authority (convert underscores to hyphens).

## Safety

- **Never `git add -A`** in this repo while a qualification target may be
  untracked in `sol/environments.local.yml` — stage explicit paths (see `AGENTS.md`).
- **Never delete a user-level root without the backup** in step 2, and never
  delete another actor's worktree.
- Do not rewrite skill bodies while migrating; migrate content faithfully and fix
  only frontmatter `name`.
- This skill moves where skills live; it does not change what they say.
