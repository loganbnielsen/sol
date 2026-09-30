---
id: FEAT-115
type: feature
severity: low
title: Let soldev pipeline merge target a pull request directly, not only a ticket
source: PR #758 (2026-09-29) — queueing auto-merge for a ticketless docs PR falls back to raw gh
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
app-author surface. State that in the completion notes.

**TypeScript parity:** No language-parity impact — `soldev` is maintainer tooling,
not part of the application contract.
