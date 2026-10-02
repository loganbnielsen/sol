---
id: INFRA-098
type: infra
severity: low
title: pipeline review cannot say a ticket's PR is already merged, only that no open PR exists
source: observed while landing BUG-115 (PR #860)
---

pipeline review cannot say a ticket's PR is already merged, only that no open PR exists

**Depends on:** None.

**Premise verified (2026-10-02)** at `origin/main` `4e426729`. `internal/tooling/soldev/lib/soldev_merge.ml:52`
builds the candidate set with `gh pr list --state open`, `:118` matches a candidate by
`ticket_id_of_branch p.pr_branch = ticket_id`, and `:575` reports
`error: no open PR found for %s (branch prefix %s/)` when nothing matches. Observed verbatim, while `BUG-115`'s
PR #860 (`BUG-115/database-suites-run`, head `8855d61d`) was already merged
(`gh api repos/loganbnielsen/sol/pulls/860` → `merged: true`, `merged_at 2026-10-02T05:37:42Z`,
`merge_commit_sha 4e426729`):

```
$ _build/default/internal/tooling/soldev/bin/main.exe pipeline review BUG-115 --result-file /tmp/BUG-115-result.json
error: no open PR found for BUG-115 (branch prefix BUG-115/)

$ _build/default/internal/tooling/soldev/bin/main.exe pipeline review INFRA-060 --result-file /tmp/BUG-115-result.json
error: no open PR found for INFRA-060 (branch prefix INFRA-060/)
```

The second command is the same run against a `READY_FOR_ENGINEERING` ticket with no PR at all: merged and
never-started are the same sentence, with the ticket id the only difference. Positive control, so this is not
a broken tool: `pipeline check REFAC-160` in the same tree prints `open PR:
https://github.com/loganbnielsen/sol/pull/863`, so the inventory is live and the open-PR path works.

## Problem

The lookup is correct; the message collapses two different states into one sentence. A ticket whose PR has
been merged and a ticket that has no PR at all — a wrong id, a ticket nobody has started — both read as
`no open PR found for <id> (branch prefix <id>/)`, with nothing to say which. The reader has to go to
`gh` to find out.

The cost was paid immediately. During BUG-115's landing the reviewer ran that command, read the message as a
lookup failure — "the tool cannot find the PR by branch prefix" — and reported a phantom tooling defect to
the operator, who asked for it to be filed. The tool had in fact answered truthfully: the PR it was asked
about was merged 90 seconds earlier, so no *open* PR existed. `AGENTS.md` already warns against reading
"merged" as "the marker step ran"; this is the mirror image, where the tool's own wording invites a wrong
belief about why it found nothing.

A second reader effect matters more than the first: because the message is identical either way, an
operator cannot use it to tell "this branch never reached a PR" from "this already landed", which is exactly
the distinction `pipeline review` is consulted for after a merge.

## Remediation

Keep the open-PR lookup, and when it finds nothing, look for a PR whose branch names the same ticket in any
state (`gh pr list --state all`, or `gh pr view <branch>` on the branch the ticket's id implies before
declaring nothing). When one is found, name it and its state — merged, with the merge commit, or closed — and
exit non-zero saying the review cannot gate a merge that has already happened, or must be reopened first.
Reserve `no open PR found` for the state it describes: no PR at all.

## Acceptance criteria

- `pipeline review <id>` for a ticket whose PR is merged names the PR and says it is merged, distinct from
  the message for a ticket with no PR at all.
- `pipeline review <id>` for a ticket with no PR at all still reports that no PR was found, and does not
  claim one is merged.
- Both messages are covered by a test in `internal/tooling/soldev/test/test_merge.ml`, which already tests
  the merge-side branch and ticket-id matching.
- `pipeline ls` / `pipeline check`, which share the open-PR inventory, are unchanged in wording.

## Non-goals

- Not a change to the gate: `pipeline merge` must go on refusing a PR with no `SOLDEV-REVIEW: PASS` marker
  for its head, and `pipeline review` must go on refusing to mark a merged PR as reviewed.
- Not a substitute for the marker discipline: the marker is still posted before the merge command runs.
