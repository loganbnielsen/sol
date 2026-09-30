---
name: review-worktree
description: Perform an optional targeted review of specified open ticket PRs and post findings through soldev pipeline review; not a mandatory merge gate.
---

# Review ticket PRs

Invoke only for requested PRs or intentionally selected high-risk changes.
Do not automatically review every routine filing/refactor. Discover PRs with
soldev pipeline ls and read the ticket from the PR tree (DONE for completed
implementation, READY_FOR_ENGINEERING for an explicitly partial PR).

Keep selected PRs draft while review is outstanding. Use one reviewer per
requested PR, in its owned worktree; inspect the diff against origin/main,
ticket intent, validation evidence, boundaries/security, and required
documentation/demo/language-parity coverage. Run additional checks only where
they add evidence, not to repeat an already valid full CI run.

**Reviewer independence.** That reviewer must be one the author did not prime —
normally a subagent. If your harness has no subagent facility, do not simulate
independence: stop and report that the requested review could not run, or, with
the operator's agreement, review it yourself and label the result a self-review.

Return structured results:

```json
{"status":"pass","summary":"what was checked","violations":[]}
```

Findings use `{"file":"path","line":42,"message":"concrete issue"}`; line may be null.
Post results with `soldev pipeline review <id> --result-file <path>`.
The marker is an informational comment, not an approval requirement. Do not move
tickets or claim a review guarantees correctness.

Fix actionable findings on the same PR and confirm them; no mandatory fresh
reviewer loop. Once selected review is satisfactory, mark the PR ready and queue
native squash auto-merge (the default). Required CI still gates it, and whoever
queued it monitors the merge to completion.
