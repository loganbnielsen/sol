---
id: INFRA-109
type: infra
severity: medium
source: the alpha.7 campaign's push of BUG-205, 2026-10-04
title: The pre-push hook evaluates the working tree, so an unrelated local patch blocks a push
---

**Depends on:** None.

## Premise verified

`internal/tooling/hooks/pre-push` execs `internal/ci/run_fast_checks.sh`, which runs whole-tree
guards against the **working tree**, not against the content being pushed. Pushing
`BUG-205/fresh-state-is-not-unreadable` — a branch that touches `cli/lib/cloud` and tickets — was
refused with `fast checks: lifecycle tests FAILED`, caused by a deliberate *uncommitted* patch in
the same worktree: `internal/qualification/gcp/test-live-qual.sh` encodes the qualification target
that patch changes. Nothing in the pushed commits was wrong, and nothing about the failure named
the file that caused it.

## Why it matters here

Uncommitted local patches are an encouraged pattern in this project — the alpha.7 campaign
deliberately ran a locally patched specimen and kept the patch out of the commits — so a single such
patch fails every push from that worktree for reasons unrelated to the push. The failure message does
not name the dirty path either, so the operator cannot see that the failure is unrelated.

## Why the bypass gets used instead of a clean worktree

Recorded because fixing the tool will not fix the behaviour by itself. The sequence was: a push failed
with a message about a file the branch never touched; the cheapest recognised escape was
`SOL_SKIP_HOOKS=1`; spinning a clean worktree looked like more ceremony than a docs-and-tickets
branch deserved. The same flag was also used on commits where the hook already self-skips
(`docs/tickets only — skipping format and build`), which had no justification at all. There are two
halves: the tool asks the wrong question, and the instructions permit a blunt answer to it.

## Remediation

Pre-push must evaluate the **pushed committed tree**, not the working tree: a clean representation of
the tip being pushed. A temporary worktree is the conceptually clean way to get one; whether a
cheaper equivalent suffices is an implementation question, not a semantic one. Keep the whole-tree
guards whole-tree — **do not path-scope them**. Whole-tree checks are what catch a change in one
directory breaking a global invariant, and that is the value being bought; scoping would trade it
away to remove a false failure.

The four gates should then read consistently: pre-commit validates what is about to be committed;
post-commit validates the resulting commit; pre-push validates the tips being pushed; CI validates
the committed repository state.

Name the dirty paths in any failure, and give pre-push its own escape (`SOL_SKIP_PRE_PUSH=1`) rather
than requiring `SOL_SKIP_HOOKS=1`, which also disarms the pre-commit format/build gate. Say in the
agent instructions that a bypass is exceptional: the normal recourse for a failure the pushed content
cannot explain is to have the pushed tree evaluated, which the fixed hook now does.

## Acceptance criteria

- Pre-push validates the pushed tip's committed tree: a worktree carrying unrelated uncommitted
  changes — including a deliberate local qualification patch — cannot make a clean push fail.
- The guards stay whole-tree; no guard is scoped to a path subset.
- A failure caused by the pushed commits still fails the push, and its message names the file.
- The escape hatch is pre-push-specific and does not disable the pre-commit format/build gate.
- `AGENTS.md`'s hook paragraph states that a bypass is exceptional and names the remedy.
- `internal/qualification/gcp/test-live-qual.sh`'s dependence on the omitting qualification target
  stays recorded where INFRA-104 owns it, so this ticket does not hide that work.
- Example impact: none; developer tooling. Language-parity impact: none.
