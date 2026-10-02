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

## Completion notes

**Premise re-verified 2026-10-02** at `origin/main` `85215bcb`, and it holds: the review lookup still built
its candidate set from `gh pr list --state open` and reported one sentence for every miss. Reproduced again
from this branch's build before the change — `pipeline review BUG-115` (PR #860 merged) and
`pipeline review INFRA-060` (no PR) printed the same `no open PR found for <id>` sentence, with the id the
only difference.

**The change.** `internal/tooling/soldev/lib/soldev_merge.ml` gains `all_prs ()`, which lists PRs in every
state (`gh pr list --state all --json number,url,headRefName,state,mergeCommit`), and
`review_lookup_error ~ticket_id ~inventory`, which turns that inventory into the sentence the reader needs:

- a PR for the ticket that is **merged** — named, with its URL and merge commit, saying there is no open PR
  to review and nothing was marked reviewed;
- a PR that is **closed** and not merged — named, with its state, saying the same;
- **nothing at all** — the original sentence, unchanged: `no open PR found for <id> (branch prefix <id>/)`;
- the all-states lookup **failed** — it says so, names the failure, and says whether the PR is merged or
  closed could not be established. A failed read is not an absence (DEC-038), so this path deliberately does
  not reuse the sentence above it.

`run_review`'s miss branch calls that function with the fresh inventory. `pipeline ls`, `pipeline check` and
the merge gate itself are untouched: `merge` still requires a `SOLDEV-REVIEW: PASS` marker for the head, and
`review` still refuses to mark a PR that is not open.

**Checks.**

- Five cases in `internal/tooling/soldev/test/test_merge.ml`: a merged PR is named with its commit and the
  message does not claim no PR exists; a closed PR is named and is not called merged; an empty inventory
  keeps the exact plain sentence; a failed inventory names the failure and claims neither merged nor absent;
  another ticket's PR is not matched. `dune exec internal/tooling/soldev/test/test_merge.exe` — 27 cases
  pass.
- **Mutation check:** turning the merged-state guard into `when false` fails the first case with `says it is
  merged` and nothing else; restored, rebuilt, green.
- Live, on this branch's build: `pipeline review BUG-115` →
  `error: BUG-115's pull request #860 (https://github.com/loganbnielsen/sol/pull/860) is already merged as 4e426729…, so there is no open PR to review; nothing was marked reviewed`;
  `pipeline review INFRA-060` → `error: no open PR found for INFRA-060 (branch prefix INFRA-060/)`.
- Guards and formatting: `dune fmt`, `check_ocamlformat.sh --all`, `check_no_comments.sh`,
  `check_operator_diagnostics.py`, `check_json_decode_boundary.py`, `check_test_reachability.py` and
  `run_fast_checks.sh`.

**Why it was worth doing rather than shrugging at.** It misled a reader immediately: during BUG-115's landing
this message was read as a lookup failure — "the tool cannot find the PR by branch prefix" — and reported as
a phantom tooling defect. The wording now names which of the four states the reader is in.

**Demo/example:** not applicable — `soldev` is maintainer tooling, not a surface an application author runs or
reads. **Language parity (DEC-022):** no impact; this changes no framework contract or convention.
