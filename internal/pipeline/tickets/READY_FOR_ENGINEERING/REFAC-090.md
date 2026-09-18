---
id: REFAC-090
type: refactor
severity: medium
title: Make worktree and ownership isolation an enforced repository rule
source: concurrent-agent session 2026-09-18 — a ticket commit landed on another
  engineer's lifecycle branch because the actor verified its commit contents but
  never resolved which branch it was committing to
premise: "rg -q -i 'worktree' CONTRIBUTING.md"
---

**Depends on:** None.

**Related:** ADR 0003 (the same authority split, applied to a repository).

## What this is

Two failures in one session had one root cause: a rule that existed but had no
enforcement point.

1. **Branch/worktree ownership drift.** A ticket commit was made from the
   canonical checkout while it happened to be on another engineer's branch. The
   actor verified the commit's *file list*, then its tests, and never resolved
   *which branch it was on* — so every check passed while the commit was in the
   wrong place. It was caught only because the branches had diverged and a push
   would have been rejected.
2. **Stale-policy discovery.** The worktree rule is real, but lives only in
   `.claude/skills/work/SKILL.md`. Actors that do not enter through `/work` —
   design review, ticket filing, verification of already-committed work — never
   pass that point and default to the canonical checkout. A rule that binds only
   its own entry point does not constrain the actors it exists to constrain.

So the fix is not "document that agents should use worktrees". It is: make the
rule authoritative repository-wide, and give it an enforcement point that an
actor *not* entering through `/work` still passes through.

## Evidence (2026-09-18, `main` at 4b33fabc)

The rule is absent from the process authority and present only in a skill:

```text
$ rg -q -i 'worktree' CONTRIBUTING.md ; echo $?
1
$ rg -n 'worktree' .claude/skills/work/SKILL.md
54:   git worktree add -b ticket-id/short-slug ../sol-ticket-id-short-slug main
70:   From **inside the worktree** (not the main checkout — there is nothing on `main` to touch)
```

`.claude/CLAUDE.md` mentions worktrees only in passing — a frontmatter note, the
`/work` description, and the post-commit hook's orphaned-worktree warning — and
never states the rule.

The pre-commit hook has no authority or context check at all
(`internal/tooling/hooks/pre-commit`): it validates ticket state transitions,
skips the suite for docs-only changes via `internal/ci/classify-changes.sh`, and
otherwise runs the suites. Nothing inspects worktree, branch, upstream or base.

**The install path itself was broken, which is how the bad commit was entirely
ungated.** In this environment:

```text
$ ls -la .git/hooks/pre-commit
.git/hooks/pre-commit -> /home/lbendtly/Code/sun/devtools/hooks/pre-commit    # dangling
$ ls devtools/hooks/pre-commit
ls: cannot access 'devtools/hooks/pre-commit': No such file or directory
```

The canonical installer (`cli/platform/local/scripts/install-hooks.sh`, the one
`CONTRIBUTING.md` documents) symlinks `internal/tooling/hooks/*` into
`.git/hooks/`, is idempotent, and backs up non-symlink hooks. Re-running it
repairs the state (verified: both hooks now resolve to
`internal/tooling/hooks/{pre,post}-commit` and are executable). Nothing in the
repository detects the broken case, so a stale install is silently inert.

No test exercises the installer: there is no offline check that installs into a
scratch git dir and asserts the symlinks resolve, so moving or renaming a hook
source can leave every developer with a dangling gate and no signal.

## What the repository can and cannot enforce

The design follows from these, so they are stated before the criteria:

- **Cannot** distinguish an agent from a human, and must not try. The canonical
  checkout is where the human works, and `CONTRIBUTING.md` states plainly that
  the pre-commit hook is not the gate — CI is.
- **Cannot** verify an "expected base" the actor never declared. A base check is
  only meaningful against a *declared* expectation, so any such check needs a
  cheap way for an actor to declare its context.
- **Can** verify cheaply and unambiguously: which worktree and branch the commit
  is on; whether HEAD is detached; whether a branch has an upstream and whether
  the upstream name matches; and whether a declared base is an ancestor of HEAD.
- **Can** verify in CI that the documented installer produces resolving,
  executable symlinks — the only way a dangling install can be caught by the
  repository rather than by luck.

## Non-goals

- Not an agent/human discriminator, and not a blanket refusal to commit in the
  canonical checkout — that breaks the human's own workflow and contradicts
  `CONTRIBUTING.md`.
- Not a hook that assumes every branch has an upstream or shares one topology.
  Local `main` commits and merges are legitimate (`soldev pipeline merge`
  fast-forwards local `main`; `merge-finish` records a perf baseline there), so
  no check may assume a feature-branch shape.
- Not a replacement for CI, and not a change to how CI classifies changes.
- Not a change to `/work`'s behaviour for tickets that already follow it — only
  its independence as the sole definition of the rule.

## Remediation

Smallest coherent fix, in dependency order:

1. State the rule in `CONTRIBUTING.md` — the process authority. The other
   documents then reference it instead of restating it.
2. Make `.claude/CLAUDE.md` and `.claude/skills/work/SKILL.md` cite that section
   rather than independently defining the policy, so there is one statement to
   keep true.
3. Add an offline install-integrity test: install into a scratch git dir, assert
   every hook in `internal/tooling/hooks/` lands as a resolving, executable
   symlink, and fail when a hook source is moved without updating the installer.
   Wire it into the same suite that runs `test_ticket_transitions.sh`.
4. Add an authority preflight to `internal/tooling/hooks/pre-commit`, ordered
   before the ticket-transition guard, that resolves the current worktree,
   branch, HEAD state and upstream, and compares them against an actor-declared
   context when one is present.

## Acceptance criteria

- `CONTRIBUTING.md` states the rule once, as policy: each concurrent actor owns
  an isolated worktree; agents do not perform mutating work in the canonical
  checkout; before commit or push an actor resolves and verifies worktree,
  branch, upstream, expected base, and ticket/PR ownership. The declaration that
  an actor may make is cheap — one command — and optional for humans.
- `.claude/CLAUDE.md` and `.claude/skills/work/SKILL.md` reference that
  `CONTRIBUTING.md` section instead of defining their own version, and no second
  statement of the policy remains to drift.
- `bash cli/platform/local/scripts/install-hooks.sh` leaves every hook in
  `internal/tooling/hooks/` installed as an executable symlink that resolves;
  the new offline test asserts this from a scratch git dir and fails if a hook
  source is renamed or moved without the installer following.
- `CONTRIBUTING.md` documents the one-line recovery for a stale install, so a
  developer who notices nothing is running knows the fix.
- The pre-commit preflight resolves worktree, branch, HEAD state, upstream name
  and (when declared) base, and:
  - **fails closed** when a declared context disagrees with reality — at
    minimum a wrong worktree, a wrong branch, or a declared base that is not an
    ancestor of HEAD;
  - **warns without blocking** when no context is declared, for the two signals
    actually present in the incident: a commit from the canonical checkout, and a
    detached HEAD with staged changes;
  - never blocks a merge commit (the hook already exits early on `MERGE_HEAD`)
    and never requires a branch to have an upstream.
- Tests pin the preflight in a scratch repository: a declared-context mismatch
  refuses the commit; an undeclared context warns and proceeds; a commit on a
  branch with no upstream is not blocked; a merge commit is not blocked.
- `CONTRIBUTING.md`'s existing "the hook is not the gate" framing survives — this
  adds a local preflight, it does not promote the hook to the authority.

**Demo/example coverage:** Internal tooling and contributor documentation; no
runnable example or demo applies, and that will be stated in the completion
notes.

**TypeScript parity:** No language-parity impact — repository tooling only.
