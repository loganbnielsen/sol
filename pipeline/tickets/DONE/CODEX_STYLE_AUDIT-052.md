---
id: CODEX_STYLE_AUDIT-052
type: refactor
severity: medium
source: style audit
---

Represent scaffold component kind as a variant instead of duplicating service, worker, and fn builders.

**Depends on:** CODEX_STYLE_AUDIT-051.

**Problem:** `cli/sun/lib/sun_cli_cmd_new.ml:141-198` repeats similar positional
string assembly for `new_svc`, `new_worker`, and `new_fn`, differing mostly by
component suffix, module template, and binary suffix.

**Goal:** Centralize component generation around a typed component kind.

**Acceptance criteria:**

- Add a component-kind variant for service, worker, and function.
- Use one helper to compute directory, library name, module name, binary name,
  and common files.
- Preserve generated file contents.

Completion: service, worker, and function scaffolds now flow through a typed
component-kind helper that computes the shared scaffold shape and writes common
files. Byte-for-byte golden tests cover all three generated component layouts,
and focused scaffold tests plus the affected CLI build pass. No baseline changes
accepted.
