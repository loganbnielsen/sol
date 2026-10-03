---
id: AUDIT-085
type: audit-finding
severity: low
title: Rollback pointer verification reports an unreadable pointer as "<none>"
source: internal/pipeline/audits/2026-10-02_error_collapse_audit.md
---

Rollback pointer verification reports an unreadable pointer as "<none>"

**Depends on:** None.

## Problem

`read_jsonpath` in `cli/lib/deploy/sol_cli_rollback.ml` returns `""` on **any**
`kubectl get` failure. `verify_pointer` uses it to read the current-release
ConfigMap's `release_id` and compares the result to the expected release;
`display_actual` renders `""` as `<none>`. A failed read therefore produces
"pointer mismatch: … names `<none>`, expected `<release>`".

## Impact

The verdict fails closed (`pointer_ok` is false unless the expected id is
literally empty), so no false success results. But the diagnosis asserts a
definite absence ("names `<none>`") from a read that did not complete — the same
shape as FND-0024/FND-0025 — so an operator chases a genuinely-missing pointer
instead of the authorization/connectivity failure that prevented the read.

## Remediation

Return a `(string, string) result` from `read_jsonpath` (or a distinct
"unreadable" case in `pointer_report`) so `pointer_report_to_string` can say the
pointer could not be read and name why, while keeping the existing fail-closed
verdict.

## Acceptance criteria

- An unreadable pointer reports the read failure and its cause; a pointer that
  was read and is empty/mismatched still reports the mismatch.
- Verification still fails when the pointer cannot be read.

**Demo/example coverage:** Not applicable — rollback verification diagnostics;
no app-author surface.

**TypeScript-parity note (DEC-022):** No language-parity impact — the OCaml CLI's
rollback transaction.

## Completion notes

Fixed 2026-10-02, `AUDIT-085/rollback-pointer-unreadable`.

- `read_jsonpath` returns `(string, string) result`; the `kubectl` failure's
  `Sol_cli_process.error_to_string` is the reason.
- `pointer_report` is now a three-way outcome — `Pointer_confirmed`,
  `Pointer_names of string` (read, names another release), `Pointer_unreadable
  of string` (the read failed, with its cause). `pointer_report_ok` is true only
  for `Pointer_confirmed`, so verification still fails closed on an unreadable
  pointer, but the diagnosis no longer asserts a definite absence.
- `pointer_report_to_string` renders the unreadable case as "pointer unreadable:
  <configmap> could not be read, so the release it names is unknown (<cause>);
  expected <release>" — `<none>` and "pointer mismatch" are reserved for a
  pointer that was actually read. `execute`'s follow-on sentence now says the
  pointer "could not be confirmed" rather than "does not read back", so it is
  true in both the mismatch and unreadable cases.
- `docs/architecture/devops-pipeline.md` step 9 records the new outcome.

Tests (`cli/test/inline/test_rollback.ml`): a fake `kubectl` on `PATH` drives
`verify_pointer` for the three outcomes — an unreadable read (exit 1 with a
`Forbidden` message) must be `Pointer_unreadable` and must not be reported as a
named release; a read that returns the expected id is confirmed; a read that
returns a different id is a mismatch. The renderer tests also pin that the
unreadable message names the cause and does not print `<none>`.

Negative (mutation) run: restoring `| _ -> ""` in `read_jsonpath` fails
`pointer_report: an unreadable read is not reported as a named release` with
"an unreadable read must not be reported as a named release"; the mutation was
reverted.

The two `Test_scaffold` inline cases fail in this fresh worktree exactly as they
do on a pristine `origin/main` worktree (`dune build` of a scaffolded
workspace), so they are environmental.

No demo/example change: rollback verification diagnostics, no app-author
surface. No language-parity impact (DEC-022).

