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

## Completion notes (2026-10-02)

**Premise re-verified** against `origin/main @ 408bc4c4`: the reporting loop the finding names
(`internal/ci/run_fast_checks.sh:122-131`, where `read -r code seconds <"$results/$index.status"`
left `code` holding the previous iteration's value) is gone. `run_fast_checks.sh` now delegates to
`internal/tooling/scripts/verify.sh`, whose reporting requires a result per member.

**Made structural by VERIF-005.** `verify.sh` writes each member's exit code and timing to its own
result file, and `report` fails any member whose `.status` file is absent or unreadable, naming it
(`FAIL    no-result  <member>`). `internal/ci/verify_test.sh` demonstrates the acceptance cases:
an all-pass result set succeeds, a non-zero result fails, and a missing result fails naming its
member; per-member `PASS`/`FAIL` lines with timings are still printed, so a failure stays
diagnosable. A member that dies before it can be reported is therefore a failure, not a `PASS`.

**Evidence.**

```
$ rg -n 'read -r code seconds|checks=\(' internal/ci/run_fast_checks.sh   # no matches
$ rg -n 'verify.sh|verify_test.sh' internal/ci/run_fast_checks.sh
54:if ! bash internal/tooling/scripts/verify.sh always; then
57:if ! bash internal/tooling/scripts/verify.sh static; then
60:if ! bash internal/ci/verify_test.sh; then
$ bash internal/ci/verify_test.sh
  [OK]   an all-pass result set reports success
  [OK]   a non-zero result fails the run
  [OK]   a missing result fails and names its member
```

**Demo/example:** not applicable — repository tooling only. **Language parity (DEC-022):** no
application-facing contract changes.
