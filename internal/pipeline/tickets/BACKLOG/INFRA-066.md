---
id: INFRA-066
type: bug
severity: medium
title: A merged implementation can leave its ticket in READY_FOR_ENGINEERING, where it still reports as actionable
source: found while picking up "actionable" work on 2026-09-22 (INFRA-048, INFRA-050, INFRA-057)
---

**Depends on:** none.

## The defect

The pipeline's own signal is wrong in a way that costs work every time it happens.
Three tickets in `READY_FOR_ENGINEERING` were reported by `soldev pipeline check` as
**`actionable`** while their implementation was already on `main`:

| Ticket | Landed in | Merging commit moved the ticket? |
|---|---|---|
| `INFRA-048` | #388 (`642162b4`) | no — 4 source files, no `internal/pipeline/tickets/` path |
| `INFRA-050` | #390 (`d8d8c876`) | no — 7 source files, no ticket path |
| `INFRA-057` | #397 (`4385100c`) + #398 (`b0d26e74`) | no |

Closed as a verified close-out on 2026-09-22 (the same branch that adds this
ticket), but they were found by accident: while
reading `INFRA-050` and `INFRA-048` to implement them, the code already contained
`(* INFRA-050: … *)` and `(* INFRA-048 / FND-0011: … *)` markers. The cost of the
miss is a wasted cycle at best — an engineer or agent reads a full ticket, checks
out a worktree and starts implementing — and duplicate/conflicting work at worst.

Note the direction of the failure: it is not that a fix was lost. It is that the
*record* says work is outstanding when it is not, so the queue over-reports and the
one signal a worker uses to choose work is unreliable.

## Why it happens

Moving `READY_FOR_ENGINEERING/<id>.md` → `DONE/<id>.md` in the final commit is a
manual step, and nothing checks that a change which implements a ticket also moves
it. All three cases above are the same shape: the code work was done carefully and
the bookkeeping was forgotten at the end.

## Remediation (options, cheapest first)

1. **Advisory sweep, no false positives.** `internal/ci/` already has the raw
   material: this repository's convention is that an implementation carries its
   ticket id in a comment. A script can list tickets in `READY_FOR_ENGINEERING` whose
   id appears in `cli/`, `framework/` or `internal/` (excluding `internal/pipeline/`
   itself) as *possibly already implemented — verify before starting*. That is
   exactly the manual check that found these three, and the cost of a false positive
   is one line of output.
2. **Surface it where the decision is made.** `soldev pipeline check <ID>` (and
   `ls`) could include the same hint for a `READY_FOR_ENGINEERING` ticket, since that
   is the command a worker runs before starting.
3. **Enforce at merge.** If a PR title or commit subject names a ticket id, require
   the PR either to move that ticket or to carry an explicit partial marker (e.g.
   `Part of: <ID>`), which the multi-part tickets (`INFRA-057`) genuinely need. More
   precise, but it needs a marker convention and a decision about what to do with the
   many historical PRs.

Recommendation: 1 and 2 first — advisory, no markers to remember, and they catch the
class where it is cheap. 3 only if the advisory version proves to be ignored.

## Also worth a pass

`BACKLOG` shows the same references (`BUG-035`, `FEAT-058`, `INFRA-005`,
`RELEASE-005` name source files), but there the consequence is milder — a BACKLOG
ticket is not in anyone's work queue — so this ticket does not claim those are stale.
The sweep in (1) should cover them and say so rather than assume.

## Acceptance criteria

1. A ticket whose implementation has merged but which still sits in
   `READY_FOR_ENGINEERING` is surfaced by a repository check — with its own test, in
   the usual shape (`check_*.sh` plus a mutation test asserting the check fires).
2. The check is advisory: it must not fail a build for a legitimate partial
   implementation or for a ticket id that legitimately appears in a comment
   (e.g. `HARDEN-002` in qualification fixtures).
3. `INFRA-048`, `INFRA-050` and `INFRA-057` do not reappear in the sweep's output.
