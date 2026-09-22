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

## Adopted design: the branch name declares the ticket

My first pass suggested an advisory sweep for the ticket id in source comments. That
was replaced by a better signal, suggested in review: **the worker already writes the
ticket id into the name it chooses**, and this repository does it consistently. The
four missed PRs are the evidence — every one of them names its ticket:

| PR | head branch |
|---|---|
| #388 | `fix/infra-048-namespace-create` |
| #390 | `fix/infra-050-secret-backend-inference` |
| #397 | `fix/infra-057a-partial-evidence` |
| #398 | `fix/infra-057b-operator-identity` |

So `(name, diff)` is enough to check, with no comment-grepping and no guessing. The
implemented check (`internal/ci/check_ticket_move.sh`) extracts ids, case-insensitively,
from the branch name, the worktree directory (`sol-INFRA-049-omit-authority`) and the
`(<ID>)` form in commit subjects — note `infra-057a` yields `infra-057`, which is what
the multi-part branches rely on. When such an id is in `READY_FOR_ENGINEERING` at the
base, the branch must have moved it to `DONE` by its head, or declare itself a part:
`(<ID>, part A)` in a subject, or `Part of: <ID>` via `--extra-text`.

Branches that name no ticket (`chore/...`, `docs/fnd-0024-0025-fixed`) pass, because
`fnd-0024` is a finding, not a ticket file — the check only fires for an id that is
genuinely a READY ticket at the base. A ticket that is not READY at the base (a
`BACKLOG` ticket being implemented, or one already `DONE`) is not required either.

Note `soldev pipeline submit` already required `DONE/<id>.md` to exist for the ticket
it is handed — which is why the gap was in everything *else*: a hand-pushed branch, or
a merge that never went through `submit`. The CI step is the backstop that covers all
of them, and it is unconditional, because a ticket move is itself a docs-only change
and would otherwise be skipped.

## Also worth a pass

`BACKLOG` shows the same references (`BUG-035`, `FEAT-058`, `INFRA-005`,
`RELEASE-005` name source files), but there the consequence is milder — a BACKLOG
ticket is not in anyone's work queue — so this ticket does not claim those are stale.
The new guard deliberately ignores them (they are not READY at the base); a sweep of
that milder case, if wanted, is its own small change.

## Acceptance criteria

1. A ticket whose implementation has merged but which still sits in
   `READY_FOR_ENGINEERING` is prevented by a repository check, not by attention.
2. The check is falsifiable — a mutation test asserts both directions (`check_ticket_move.sh`
   plus `test_ticket_move.sh`, in the shape the other guards use).
3. Legitimate shapes are not blocked: a branch naming no ticket, a finding-only branch,
   a ticket that is not READY at the base, one already `DONE`, and a declared partial.
4. Applied to the four historical branches above, each would have been refused.

## Completion (2026-09-22)

Implemented as designed above.

- `internal/ci/check_ticket_move.sh` — the guard. Reads the branch name, the worktree
  directory name and `(<ID>)` in commit subjects; requires a named READY ticket to be
  in `DONE` at the branch head, unless the branch declares a part. Handles both ticket
  roots (`internal/pipeline/tickets` and the legacy `pipeline/tickets`).
- `internal/ci/test_ticket_move.sh` — the mutation test, ten expectations: the refusal,
  that the refusal names the ticket and the fix, that landing the ticket satisfies it,
  and that a branch naming no ticket, a finding-only branch, a non-READY ticket, an
  already-`DONE` ticket and a declared partial all pass. It also pins that the partial
  marker does not leak: the same ticket on a different branch without the marker is
  still refused.
- `.github/workflows/ci.yml` — two steps, deliberately **unconditional** (no
  `classify` condition), because a ticket move is a docs-only change and the
  classification would otherwise skip precisely the PRs this checks.
- Verified against this repository, not only the fixture: run against `BUG-033`'s
  in-flight branch it reports `✓ BUG-033/no-local-revert moves BUG-033 to DONE`, and
  against this ticket's own branch (a `BACKLOG` ticket, so nothing is required) it
  passes silently.

**Not added:** a submit-time call. `soldev pipeline submit` already refuses to run
unless `DONE/<id>.md` exists for the ticket it is handed, so the pre-existing hole was
every path that does not go through `submit` — a hand-pushed branch, which is how all
four historical cases actually merged. CI is the right place for that backstop.

**Self-consistency:** this branch is named `INFRA-066/branch-names-the-ticket` and lands
this ticket in `DONE`, so the guard it adds passes its own PR.
