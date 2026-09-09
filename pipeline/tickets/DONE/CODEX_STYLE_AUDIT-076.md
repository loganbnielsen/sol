---
id: CODEX_STYLE_AUDIT-076
type: refactor
severity: low
source: docs/audits/STYLE_AUDIT.md
---

`Soldev_merge.run_merge`/`run_merge_finish` take unlabeled positional bool/string args

**Depends on:** none.

**Problem:** `devtools/soldev/lib/soldev_merge.ml:241` — `run_merge dry_run accept_performance_regression ticket_filter` takes two positional `bool` arguments back to back with no labels. `run_merge_finish ticket_id merge_sha accept_performance_regression` (line 173) takes two positional `string` arguments (`ticket_id`, `merge_sha`) plus a trailing positional `bool`, also unlabeled. Both are currently only called via Cmdliner `Term` wiring in `devtools/soldev/bin/cmd_pipeline.ml`, where the named `*_flag`/`*_arg` terms make each call site self-documenting today — but the underlying function signatures themselves offer no compiler protection against a swapped argument order if either is ever called directly from OCaml (e.g. from a future test, or a refactor that inlines the Cmdliner wiring), and reading the function definition alone (as anyone extending this module will) gives no indication which positional bool means what without checking every call site.

**Goal:** Convert both functions' positional arguments to labeled arguments, so `run_merge ~dry_run ~accept_performance_regression ~ticket_filter` (and similarly for `run_merge_finish`) is unambiguous at both the definition and any future call site, matching this codebase's own general preference for labeled args on multi-parameter functions of the same primitive type (see the auth/route/service modules in `framework/sol-svc/` for the established convention).

**Acceptance criteria:**

- `run_merge` and `run_merge_finish` take labeled arguments for all bool and string parameters (labels can be inferred from current parameter names).
- The Cmdliner `Term` wiring in `cmd_pipeline.ml` is updated to match (labeled application, `~label:term` or equivalent).
- Existing `devtools/soldev/test/` tests for these functions (if any call them directly) are updated to the new signature; full `devtools/soldev/` test suite still passes.
