---
id: INFRA-011
type: infra
severity: low
source: FEAT-060 (#213) squash subject; earlier, a **Status:** line became a backlog summary
---

**Depends on:** None.

# The ticket body decides the PR title and the backlog summary, and the rule is written down nowhere

## Problem

The pipeline derives user-visible text from a ticket body by a rule that has never been stated:

- **PR titles / squash subjects** come from the ticket's first non-metadata line, prefixed with the id. FEAT-060's body opened with `**Depends on:**` followed by a paragraph of reasoning, so #213's squash subject is that paragraph: `FEAT-060: FEAT-056 is DONE, but two of its criteria are not: SOL_ENV is only asserted for services...` — a sentence where a title belongs, and now permanent in `git log`.
- **Backlog summaries** (what `soldev pipeline ls` shows) come from the first line too. A ticket that led with `**Status:** …` displayed its status as its summary until the line was removed.
- **Novel metadata prefixes are not skipped, so they become the summary.** Reproduced while filing this ticket: `**Related:** DEC-016, DEC-020, FEAT-057.` and `**Replaces:** the enforcement half of FEAT-058` are now the displayed summaries of FEAT-058 and FEAT-059 respectively. Any prefix outside the hard-coded skip list is treated as content.
- **A heading is taken verbatim, marker included.** This ticket's own summary displays as `# The ticket body decides the PR title and the backlog summary, and the rule is written down nowhere`.

Both are the same defect: **the tooling infers intent from position and skips only the markers it happens to know about**, so any body that doesn't happen to open with a title produces a wrong-looking subject or summary. The convention that avoids it ("put a short title line first") is implicit knowledge, and it has cost three corrections this week — the third being this ticket's own two fields, which reproduced the bug within minutes of filing it.

## Proposed fix

Any of these; the first is the substantive one:

1. **Let the ticket say it.** Accept a `title:` (or `summary:`) field in the frontmatter and use it when present, falling back to the current rule. Intent stated beats intent inferred, and it survives body edits.
2. **Make the fallback deterministic and documented.** If there is no explicit title, prefer the first Markdown heading (H1/H2) in the body; otherwise the first non-frontmatter line, with the known metadata prefixes (`**Depends on:**`, `**Status:**`, `**Blocked by:**`) skipped by an explicit list rather than by luck.
3. **Write the rule down** wherever ticket authoring is described (`.claude/CLAUDE.md`, or the docs map), including both incidents as the reason it matters.

## Acceptance criteria

- A ticket that opens with `**Depends on:**` and then prose produces a sensible PR title (reproduces the FEAT-060 case).
- A `**Status:**` line is never used as a backlog summary (reproduces the earlier case).
- An explicit title, when provided, wins over any inference.
- The rule is documented in one place, and the docs say what happens when no title is given.

## Notes

## Completion notes

**The fix is two rules, and the second one is what generalises.** An explicit `title:` frontmatter field wins outright when present and non-blank. Otherwise the title is the first body line that is not a **bold-labelled field**, with Markdown heading markers stripped — recognising the *shape* (`**Label:**`) rather than listing labels, because a list is what failed: `**Status:**` was known, then `**Related:**` and `**Replaces:**` were not, and each shipped as a displayed summary before anyone noticed.

**Deviation from the third proposal, deliberately.** The ticket suggested preferring the first Markdown heading anywhere in the body. Not implemented: a ticket that opens with prose and later has `## Problem` would then be titled "Problem". Taking the *first content line* and stripping markers if it happens to be a heading is both simpler and can't pick a section heading far from the top. Every observed case — `# ...` titles, plain-sentence titles, labelled-field openings — is handled.

**Both surfaces fixed at once.** `ticket_title` feeds the PR subject (`soldev_merge.ml:294`) and the listing summary (`:810`), so one change covers the two symptoms that were reported as separate incidents.

**Tests.** Four added, alongside the two that existed: the explicit field winning, heading markers stripped, a second bold field skipped (`**Related:**`, the observed failure), and a blank `title:` falling back rather than producing an empty title. A first attempt at the bold-field rule checked for `**` *before* the colon; the marker is after it (`**Label:**`), so it matched nothing and four tests failed — the failures caught it, and the comment on the function now records the shape so the next reader does not repeat it.

**Verification.** The listing no longer shows a leading `#` on this ticket or INFRA-012 — the visible symptom, checked directly rather than inferred from the unit tests.

Low severity by impact, but it lands in `git log` permanently and it has already caused two corrections, which is the definition of a convention that should be explicit rather than remembered.
