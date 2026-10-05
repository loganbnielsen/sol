---
id: INFRA-111
type: infra
severity: medium
source: DEC-066, and the gap found while encoding it, 2026-10-05
title: Let /work start a stacked ticket from its prerequisite's branch
---

**Depends on:** DEC-066.

## Premise verified

DEC-066 endorses stacking: when ticket B depends on ticket A, B branches from A's branch, opens its PR
against that branch, and proceeds while A is in review. The canonical entry point rejects exactly that.
`AGENTS.md` § *Ticket dependencies* requires `/work` to verify dependencies before creating a worktree
and to treat a ticket whose dependencies are not in `DONE/` as blocked, and `soldev pipeline check`
and `ls` report the same. An actor following DEC-066 therefore has to route around the tool — create
the worktree and branch by hand, then open the PR with an explicit base — and that workaround is
invisible to the queue and undocumented in the tool.

## What this ticket changes

`/work`, and any `soldev` command it delegates to, gains an **explicit stacked start** that names the
prerequisite whose branch is the base. The rule stays executable rather than prose: the tool validates
it, the skill calls the tool.

- A stacked start names the prerequisite, e.g. `/work <B> --stack-on <A>`, or
  `soldev pipeline start <B> --stack-on <A>` if the check belongs in `soldev`.
- It refuses unless A is a declared dependency of B (`**Depends on:**` names A). A stack is not a way
  to base work on an arbitrary branch.
- It refuses when A is unresolved: `## Open Questions`, `## Decision Required` or `## Blocked On`
  present, or A not in `READY_FOR_ENGINEERING`. DEC-066's limit, enforced rather than remembered.
- On success it creates B's worktree from **A's branch** and not `origin/main`, under B's own branch
  name, and opens B's PR with `--base <A's branch>`.
- Ownership is untouched: one actor, one worktree; B's branch moves B's ticket.

## What must not change

- **Cold starts keep the rejection.** With no explicit stack, a ticket whose dependencies are not in
  `DONE/` is still blocked, with the same message and the same exit status.
- **Merge ordering is preserved.** B still cannot merge before A: `soldev pipeline check` and
  `pipeline merge` keep reporting the unmet prerequisite, and DEC-066's retarget step stays the path
  (B's PR retargeted to `main` after A lands — `CONTRIBUTING.md` § *Isolation and ownership*).
- The ticket-move guard keeps holding B's branch to moving B's ticket, and the pre-push hook
  (INFRA-109) is unaffected.
- Review and merge of a stacked PR stay ordinary: it is a normal PR whose base is another branch until
  it is retargeted.

## Acceptance criteria

- `--stack-on` creates B's worktree from A's branch and opens B's PR against it, and each refusal case
  fails with a message naming its reason: A is not a dependency of B, A is unresolved, A is not READY.
- With no flag, the cold-start rejection is exactly what it is today, pinned by a test.
- `pipeline ls` and `pipeline check` distinguish a stacked ticket from a cold-start one, so an operator
  can see which PRs wait on a prerequisite branch rather than on `main`.
- An end-to-end check: A ready, B depends on A, stack B, land A, retarget B, land B — the dependency
  reporting goes from unmet to satisfied, and nothing in the sequence is done by hand except the
  retarget.
- The `/work` skill documents the stacked start and points at DEC-066 for the policy;
  `CONTRIBUTING.md` § *Isolation and ownership* keeps the mechanics.
- Example impact: none; developer tooling. Language-parity impact: none.
