---
id: FEAT-115
type: feature
severity: low
title: Let soldev pipeline merge target a pull request directly, not only a ticket
source: PR #758 (2026-09-29) — queueing auto-merge for a ticketless docs PR falls back to raw gh
premise: "rg -q -- '--pr' internal/tooling/soldev/bin/cmd_pipeline.ml"
---

**Depends on:** None.

**Related:** `REFAC-159` (the merge default in the same command),
`AGENTS.md` § *Shepherding PRs to merge*, and the ticketless PRs this repository
files regularly (#752, #756, #758).

## Premise

Checked 2026-09-30 at `origin/main` `488741f4`: `soldev pipeline merge` resolves its
target by ticket only. The positional is "Ticket to merge (e.g. EXP-005) — looked up
by its open PR, not a local directory. Omit to sweep every open PR whose branch looks
like `<TICKET-ID>/....`" (`internal/tooling/soldev/bin/cmd_pipeline.ml:18-20`), and
`soldev_merge.ml` matches on that ticket/branch shape. There is no way to name a pull
request.

Re-verified 2026-09-30 at `origin/main` `24f45f43` (main had moved from `488741f4`
since the ticket was filed): still no `--pr` flag in `cmd_pipeline.ml` and still no
way to name a pull request. The frontmatter probe states the same check as a command;
it succeeds once `--pr` exists, so it reads as stale exactly when this ticket is done.

## The gap

Ticketless PRs are a normal part of this repository's workflow: the docs, policy and
roadmap changes (#752 the experience doc, #756 the DEC-021 amendment and tickets,
#758 the auto-merge policy) all name no ticket, deliberately — a branch that names a
`READY_FOR_ENGINEERING` ticket would trip the ticket-move guard.

Those PRs cannot be targeted by `soldev` at all, so queueing their auto-merge falls
back to raw `gh pr merge <n> --auto --squash --match-head-commit <sha>`. That is the
path the auto-merge default depends on most: docs-only and ticket-only PRs are the
ones the change classifier already routes down the fast path, and they are exactly
the ones an agent must still queue by hand, outside the tool that is supposed to
enforce the policy.

## Remediation

- Accept a pull request as the merge target, additively: `soldev pipeline merge --pr
  758`, or a positional that is unambiguously a PR (`#758`, a PR URL). Keep the ticket
  id positional and the sweep behavior as they are.
- Resolve the same prerequisites for a PR target: non-draft, required checks
  configured, head pinned for the merge, named refusal when a prerequisite fails.
- Keep the `--auto`/immediate semantics identical to the ticket path, and consistent
  with `REFAC-159` once that lands.
- Report the same outcome shape: merged versus queued, with the head SHA.

## Non-goals

- Not a change to ticket resolution, the sweep, or the branch-shape matcher.
- Not the flag/default question — that is `REFAC-159`.
- Not arbitrary GitHub refs beyond a pull request number or URL.

## Acceptance criteria

- A ticketless PR can be queued for auto-merge through `soldev` by PR number, with no
  raw `gh pr merge` needed.
- Prerequisite and head-pinning behavior matches the ticket path; a draft PR, or one
  with unresolved prerequisites, is refused with a named reason.
- Existing ticket-targeted invocations and the no-argument sweep are unchanged.
- A test covers the PR-number path, including the refusal cases.
- Once this lands, `AGENTS.md`'s merge section can drop the "use raw `gh pr merge` for
  a ticketless PR" fallback (update it in the same change).

**Demo/example coverage:** Not applicable — internal maintainer tooling with no
app-author surface, so there is no runnable example to update.

**TypeScript parity:** No language-parity impact — `soldev` is maintainer tooling,
not part of the application contract.

## Completion

**What changed.** `--pr` accepts a number, `#number`, or a `/pull/<n>` URL, and
`run_merge` takes `~pr_target`; a `--pr` and a ticket positional together are refused
rather than guessed at. Candidates became a `merge_target` — `Ticket_target` |
`Pull_request_target` — and each refusal is now a value (`merge_refusal`, rendered by
`merge_refusal_message`) instead of four interleaved `if`s, so every gate is named and
directly testable: `Ticket_prerequisites_unresolved`, `Refused_draft`,
`Refused_no_required_checks`, `Refused_checks_unreadable`, `Refused_checks_not_green`.
Parsing is strict by design — `fix/42` is not a PR number; only a bare number, a
`#number`, or a URL containing `/pull/` is.

**One deliberate asymmetry, and why.** A `--pr` target must have required checks
configured on its base branch before it will queue; the ticket and sweep paths keep
their previous behaviour, because `REFAC-159` scopes itself to the default and says
the prerequisite checks are unchanged. This closes the case `--pr` newly exposes: on a
branch with no required checks, GitHub's auto-merge has nothing to wait for and merges
at once, so "queue" would silently have meant "merge without CI". A `--pr` whose branch
names an existing ticket still gets the ticket-prerequisite gate; a ticketless branch
does not, which is the point of the flag.

**The `AGENTS.md` fallback had already gone.** The acceptance criterion asks for the
"use raw `gh pr merge` for a ticketless PR" fallback to be dropped; `rg -i ticketless`
over the whole tree (outside `internal/pipeline/tickets/`) returns nothing, so there was
no such text left to remove. `AGENTS.md` and `CONTRIBUTING.md` now name `--pr` as the
ticketless path instead, in the same change.

**Validation:** `dune build` clean. `internal/tooling/soldev/test/test_merge.exe` —
18 tests, 2 added (target parsing; the PR-number path end to end against a stubbed
`gh`). The end-to-end test queues by number, `#number` and URL with the head pinned,
then asserts each refusal through the captured output: draft, unresolved ticket behind
the PR, no required checks configured, `--immediate` on pending checks — and that the
default queues the same pending PR instead of merging it, while `--immediate` on green
CI merges without `--auto`. The junk-target, unknown-number and both-targets errors are
asserted by message. A mutation disabling the PR-path required-checks rule was run and
failed the suite for exactly that assertion. Full required CI on the PR head.

**Remaining limitation:** none known. Ticket resolution, the sweep and the branch-shape
matcher are untouched, and a PR target must be an open PR — a merged or closed number
is refused by name.
