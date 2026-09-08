---
id: REFAC-059
type: audit-finding
severity: low
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-059/contains-helper
worktree: ../sun-REFAC-059-contains-helper
---

Extract `contains_pattern` helper to eliminate 15 repeated exception-to-boolean idioms in `test_deployment_plan.ml`

**Depends on:** None.

**Description:**

`cli/sun/test/test_deployment_plan.ml` contains at least 15 identical occurrences of this pattern:

```ocaml
(try ignore (Str.search_forward re s 0); true with Not_found -> false)
```

For example, lines 119, 121, 128, 142, 370, 376, 387, 398, 409, 415, 427, 434, 436, 443, 445.

Each occurrence:
1. Silently swallows an exception to return a boolean.
2. Cannot be easily `grep`-ped for a specific pattern string since the pattern is assembled inline.
3. Duplicates boilerplate that hides the intent.

A similar `Error _ -> true | Ok _ -> false` pattern appears in `sun_cli_secret.ml:224` and `test_env_target.ml:139`.

**Remediation:**

Extract a module-local helper in the test file:

```ocaml
let contains re s = try ignore (Str.search_forward re s 0); true with Not_found -> false
```

Replace all 15 occurrences with `contains (Str.regexp "pattern") s`. This is a one-line change per site.

For the `Error _ -> true | Ok _ -> false` pattern in production code, replace with the stdlib combinator `Result.is_error` (available since OCaml 4.08).

## Review — automated checks passed
All 15 inline Str.search_forward idioms replaced with contains helper, both Result.is_error substitutions applied, build clean, no ticket files modified.
