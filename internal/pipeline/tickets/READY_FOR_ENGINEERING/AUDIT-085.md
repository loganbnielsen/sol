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
