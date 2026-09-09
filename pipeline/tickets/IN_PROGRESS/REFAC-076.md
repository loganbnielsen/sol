---
id: REFAC-076
type: bug
severity: low
source: found while working FEAT-035, 2026-09-08
branch: REFAC-076/depends-parse
worktree: ../sol-REFAC-076-depends-parse
---

**Depends on:** None.

`soldev pipeline check` misreports annotated "Depends on:" lines as blocked

## Problem

`soldev pipeline check`'s dependency parser doesn't strip parenthetical annotations from a ticket's `**Depends on:**` line (e.g. `**Depends on:** FEAT-033 (done — merged as the evidence base for this ticket).`). It appears to treat the whole annotated string as an unresolved dependency reference rather than extracting the bare ticket ID and checking whether that ticket is in `DONE/`. Confirmed on `FEAT-035`, `INFRA-004`, and `INFRA-005` — all misreported as blocked-by-dependency despite either having no real unmet dependency or citing an already-`DONE` ticket.

## Impact

Low — doesn't block the actual `/work` pipeline (worktree creation and submission for these tickets worked fine), but makes `soldev pipeline ls`/`check`'s dependency-status column unreliable, which undercuts its whole purpose as a quick at-a-glance view of what's actually ready to pick up.

## Remediation

Fix the dependency-line parser (likely in `devtools/soldev/lib/soldev_ticket.ml` or wherever `Depends on:` is parsed) to extract just the leading ticket ID token(s) from the line, ignoring any trailing parenthetical/prose annotation, before checking each referenced ticket's status.

## Acceptance criteria

- `soldev pipeline check` (or `ls`) correctly reports `FEAT-035`/`INFRA-004`/`INFRA-005` (or whatever their state is by the time this is picked up) without falsely flagging them as blocked by an already-`DONE` dependency.
- Add a unit test in `devtools/soldev/test/` covering an annotated `Depends on:` line.
