---
id: FEAT-040
type: feature
severity: low
source: INFRA-006 implementation session 2026-09-09
---

**Depends on:** None.

`soldev pipeline ls`/`check` should surface READY_FOR_ENGINEERING tickets whose worktree already has uncommitted changes.

## Problem

REFAC-077 deliberately removed local "in progress" state: an open branch/worktree plus GitHub PR is the source of truth. But uncommitted work in a worktree is invisible to `soldev pipeline ls`, which only annotates tickets with `(PR #N open)`.

During INFRA-006, the worktree already contained a large unfinished implementation — `.ocamlformat`, CI changes, a staged `READY_FOR_ENGINEERING → DONE` ticket move, and ~200 files of formatter drift — yet `soldev pipeline ls` showed the ticket as a plain actionable READY ticket with no PR. The only way to notice was manually checking `git worktree list` + `git -C <worktree> status`.

This creates two risks:

- A new worker can pick up the ticket and start a second worktree/duplicate effort.
- The existing uncommitted work can be accidentally discarded or left stranded if the worktree is cleaned up.

## Goal

When a READY_FOR_ENGINEERING ticket has an associated local worktree with a dirty working tree or unpushed commits, pipeline tooling should call that out so an orchestrator can resume rather than re-start the ticket.

## Remediation

- In `soldev pipeline ls` (and `soldev pipeline check <id>`), for each READY ticket, check `git worktree list` for a branch matching `<ticket-id>/...`.
- If a matching worktree exists:
  - Annotate with the worktree path.
  - If `git -C <worktree> status --porcelain` is non-empty, annotate with `(dirty worktree)`.
  - If the branch has commits not present on `origin`, annotate with `(unpushed commits)`.
- Keep it informational; do not create a new ticket state or block dispatch.
- Update `.claude/skills/work/SKILL.md` to mention that when a dirty worktree is reported, the correct action is to resume it rather than create a fresh worktree.

## Acceptance criteria

- A READY ticket with a dirty worktree shows a `(dirty worktree: <path>)` marker in `soldev pipeline ls`.
- A READY ticket with no worktree shows no new marker.
- Unit tests cover the parsing/annotation logic.
