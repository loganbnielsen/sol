---
id: FEAT-029
type: feature
severity: medium
source: docs/planning/LIVE_DEV_DEPLOY_ROADMAP.md
branch: feat-029-uses-reference-validation
worktree: ../sun-feat-029
pr: https://github.com/loganbnielsen/sun/pull/131
---

`Sun_cli_config`: validate `uses` references; add absolute cross-region refs and v1 rejection rules.

**Depends on:** FEAT-025.

## Problem

Split out of `FEAT-025` as its own reference-grammar/validation ticket:

1. **`uses` refs are never validated** against declared resource names —
   a service can name a resource that doesn't exist and `load_for_target`
   returns `Ok` anyway.
2. **No absolute cross-region refs.** `uses` is a flat string list with no
   support for `/us-east-1/analytics_db`-style absolute references, and
   none of `LIVE_DEV_DEPLOY_ROADMAP.md`'s v1 rejection rules exist:
   - `/us-east-1/analytics_db` — valid: same env/provider, different region.
   - `/prod/aws/us-east-1/db` — invalid: carries an env segment, cross-env
     sharing is not supported.
   - `/gcp/us-central1/db` — invalid: carries a provider segment, reserved
     for future multi-cloud support, rejected in v1.
3. `LIVE_DEV_DEPLOY_ROADMAP.md` line 142 also requires `sun plan` to
   *print* a resolved absolute ref distinctly as cross-region access, not
   just resolve it silently the same way as a local ref — `cmd_plan.ml`'s
   output needs a line for this once refs exist (currently it only prints
   `uses` as a flat list, see `cmd_plan.ml:44`).

## Remediation

1. After parsing, validate every service's local (non-`/`-prefixed) `uses`
   entries resolve to a declared resource name in the merged config;
   `Error` listing the unresolved name(s) otherwise.
2. Parse a `/`-prefixed `uses` entry as `/<region>/<resource>` (2 segments)
   — valid only within the current target's own env/provider. Reject (parse
   error) a 3-segment ref (env + region + resource — cross-env) and a
   2-segment ref whose first segment matches a known provider name
   rather than a region (cross-provider), per the exact examples above.
3. Update `cmd_plan.ml`'s `uses` printout (line ~44) to label an absolute
   ref distinctly (e.g. `uses: app_db, /us-east-1/analytics_db (cross-region)`)
   per roadmap line 142, rather than printing it identically to a local ref.
4. Tests: unresolved local ref, valid absolute same-env/provider ref,
   cross-env ref rejection, cross-provider ref rejection, `sun plan`
   output distinguishing a cross-region ref from a local one.

## Acceptance criteria

- A `uses` entry naming an undeclared resource fails `load_for_target`
  with an error naming the missing resource.
- `/us-east-1/analytics_db` resolves; `/prod/aws/us-east-1/db` and
  `/gcp/us-central1/db` both fail to parse, each with a message naming
  which rule (cross-env / cross-provider) it violates.
- `sun plan <target>`'s printed output visibly distinguishes a resolved
  cross-region `uses` ref from a local one.

## Review — automated checks passed
Recovered from an orphaned pre-existing worktree, rebased clean onto main, build/full suite green. Two independent fresh adversarial review rounds: first found 3 real gaps against acceptance criteria (2-segment cross-provider misclassification, empty-segment misclassified as cross-env, invented azure support); all fixed with 2 new regression tests; second round independently verified all three fixes correct via exhaustive ref-shape walkthrough and confirmed no azure references remain anywhere in repo. Diff scoped correctly, no project/tickets/ changes on branch.
