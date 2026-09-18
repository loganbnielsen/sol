---
id: INFRA-009
type: feature
severity: medium
source: 2026-09-10 — business content in this repo's published history, now that sol-cloud is private
---

**Depends on:** DEC-019.

Remove business, pricing and go-to-market content from this repository's **published history**, now that such content belongs in the private `sol-cloud` repository.

## Findings from reconnaissance

- **No credentials in history.** A scan for high-signal secret patterns — AWS access keys, private key blocks, GitHub/Slack/OpenAI token shapes — found nothing. So this is a cleanliness and positioning exercise, not credential exposure, and nothing needs rotating.
- **History is 118 commits, and its first commit is already a squash:** `Sol: squashed pre-alpha history baseline (2026-06-10 through 2026-09-08)`. History has been squashed here before, so the granularity at stake is roughly the period since that baseline.
- **The business content is woven through, not confined to a few paths.** Tickets are edited in most commits, and 172 commits across all refs touch `pipeline/` or `docs/planning/`. Surgical path filtering would therefore rewrite most of the history for little gain.

## Recommended approach

**Move the history, then reset the public repo to a clean baseline.**

1. **Import the existing history into `sol-cloud`** first, so the business and strategy reasoning is preserved privately rather than discarded. The content should *move*, not die.
2. **Reset this repository to a single fresh baseline commit** containing the tree without the moved content — business decisions, GTM material, hosted-platform tickets.
3. **Force-push**, accepting that commit SHAs and pull-request references from before the reset no longer resolve.

This is consistent with the existing baseline and takes the least work for the most certainty, given the content is not confined to identifiable paths.

## Caveats that shape the choice

- **A rewrite does not make old content unreachable.** GitHub keeps pre-rewrite objects addressable by SHA, and any fork keeps them. For genuine removal you must ask GitHub Support to run a garbage collection, or delete and recreate the repository — the latter losing stars, issues and pull-request history.
- **Do it before the repository attracts contributors.** The cost grows with forks, stars and referenced SHAs; it is cheap now and stays cheap only while there is little to break.
- **Do not leave dangling references.** DEC-016 and DEC-017 reference decisions that would move to `sol-cloud` (see DEC-019's handover list). Those references must be inlined or removed — a public document pointing at a private repository is a dead end, and DEC-019 forbids it.

## Decision Required

**Method** — fresh baseline squash (recommended, and consistent with the existing baseline); surgical path filtering (more work, little gain here); or delete-and-recreate (only if genuine removal is required and losing stars, issues and PRs is acceptable).

**Timing** — after `sol-cloud` exists and has imported the history, and before the project attracts contributors.

## Completion

**Method: fresh baseline squash** — chosen over surgical path filtering (which would have rewritten most of the history anyway, since tickets are touched by most commits) and over delete-and-recreate (which would have cost stars, issues and pull-request history for no benefit here).

**Order of operations**, which matters because the preservation step is what makes the rest safe:

1. The full pre-reset history was pushed to the private platform repository as `archive/sol-public-history-2026-09-11`, with its head SHA verified identical to this repository's `HEAD` **before** anything was deleted, and the moved content confirmed present there.
2. The five business and platform tickets were removed from this tree, and every reference to them was inlined or rewritten — `DEC-016` (three places), `DEC-018`, `INFRA-006` — so no public document points at something that no longer exists here.
3. `main` was replaced with a single baseline commit and force-pushed. The baseline commit message records why, so a future reader meets the explanation before the confusion.

**What this does not achieve.** A rewrite does not make old content unreachable: pre-rewrite objects remain addressable by SHA on GitHub, and in any fork, until the host garbage-collects them. Genuine removal needs a support request or deleting and recreating the repository. That was accepted knowingly — nothing removed was a credential (a scan for AWS keys, private keys and common token shapes found nothing, so nothing needed rotating), and the goal was to stop *publishing* business strategy, not to make it unrecoverable.

**Timing was the point.** It cost 118 commits and their SHAs, which is cheap now and would not have been once there were forks.

## Acceptance criteria

- No business, pricing or go-to-market content in the published tree or in reachable history ✅
- `sol-cloud` holds the preserved history and the moved content ✅
- No document or decision in this repository references a private repository, dashboard or runbook ✅ — references inlined rather than pointed at
- The reset is recorded in the repository itself ✅ — in the baseline commit message
