---
id: DOCS-014
type: docs-finding
severity: low
source: architecture discussion 2026-09-09 (networking reference/demo gap)
---

**Depends on:** None.

Make "a feature ticket must update a runnable example/demo, or say why not" an explicit standing convention in the agent guidance, so reference coverage does not depend on someone remembering it.

## Problem

FEAT-041 (service-to-service calls) and FEAT-042 (ingress) each changed what an app author does — a new `sol.toml` field, generated manifests, and new env/credential wiring — but neither touched an example or demo. The only thing exercising either is the `golden-path-smoke` CI job on a throwaway scaffolded workspace: a test, not a reference a user can read or run. The gap was noticed only after both PRs were already open. (FEAT-046 now covers the demo itself; this ticket is about the convention that would have caught it during implementation.)

The guidance agents follow — `/work`'s implementation step, `/review-worktree`'s subagent checklist, and the ticket conventions in `.claude/CLAUDE.md` — says nothing about examples, so "add a demo" is invisible to both the implementer and the reviewer.

## Goal

The convention is written where the implementer and the reviewer both read it, and is checkable: a feature ticket either updates a runnable example/demo, or states in one line why none applies.

## Remediation

- Add a short "Demo/example coverage" convention to `.claude/CLAUDE.md`'s ticket-system section.
- Add a matching reminder to `/work`'s implementation step (`.claude/skills/work/SKILL.md`).
- Add a matching item to `/review-worktree`'s subagent checklist (`.claude/skills/review-worktree/SKILL.md`) so a missing demo is a reviewable violation.
- Keep it proportionate: internal refactors and pure documentation are exempt with a one-line reason; "the CI smoke covers it" is explicitly not sufficient.

## Acceptance criteria

- `.claude/CLAUDE.md`, `.claude/skills/work/SKILL.md`, and `.claude/skills/review-worktree/SKILL.md` each state the rule.
- A reader of `/work` or `/review-worktree` cannot complete a feature ticket that changes app-author surface without either touching a demo or recording the exemption.
