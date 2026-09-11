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

Both are the same defect: **the tooling infers intent from position and skips only the markers it happens to know about**, so any body that doesn't happen to open with a title produces a wrong-looking subject or summary. The convention that avoids it ("put a short title line first") is implicit knowledge, and it has cost two corrections this week.

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

Low severity by impact, but it lands in `git log` permanently and it has already caused two corrections, which is the definition of a convention that should be explicit rather than remembered.
