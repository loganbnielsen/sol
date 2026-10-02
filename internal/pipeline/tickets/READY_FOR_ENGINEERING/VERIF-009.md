---
id: VERIF-009
type: bug
severity: medium
title: The pre-push gate reports PASS for a check that produced no result
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
---

The pre-push gate reports PASS for a check that produced no result

**Depends on:** VERIF-005.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`:
`internal/ci/run_fast_checks.sh:122-131` reads each check's result with
`read -r code seconds <"$results/$index.status"`. If `run_check` (line 105) dies before writing that
file, `read` fails, `code` retains the previous iteration's value, and the loop prints `PASS` and
leaves the result out of `failed`. Reproduced in isolation with one status file deleted:

```
PASS    3s  0
PASS    3s  1        <- status file absent; code carried over as 0
failed count: 0  (expected 1)
```

Since the script's exit status is `[ ${#failed[@]} -eq 0 ]` (line 141), this is a false success for
the whole pre-push gate, not a display defect.

## Problem

A check that produced no result is indistinguishable from one that passed. The trigger is narrow —
`run_check`'s shell must be killed before it writes, e.g. by an OOM kill — but the consequence is
"the local gate reported success without running everything", which is exactly the class this audit
exists to remove, and the same pattern will recur in whatever runner replaces this list (VERIF-005).
It is also a small instance of a broader rule: a missing result must never be treated as a clean
observation.

## Desired invariant

Every member of a verification class must produce a result, and a missing or unreadable result is a
failure that names the member. The runner's exit status is a function of results it actually read.

## Remediation

Default the read to a failure, and assert the result file exists before reading it. In the class
runner VERIF-005 introduces, make the same property structural: discover members, require a result
per member, refuse an empty class, and fail naming any member with no result. Cover it with a case
that deletes a result file.

## Acceptance criteria

- A deleted or unreadable result file makes the runner exit nonzero and name the member.
- A check that dies mid-run cannot yield a passing gate, demonstrated by a test that removes a
  result between execution and reporting.
- The reporting still prints per-check pass/fail with timings, so a failure remains diagnosable.
- Demo/example: not applicable — repository tooling only. Language parity: no application-facing
  contract changes; state that in one line.
