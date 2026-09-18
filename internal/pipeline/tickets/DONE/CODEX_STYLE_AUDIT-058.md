---
id: CODEX_STYLE_AUDIT-058
type: refactor
severity: medium
source: style audit
---

Render Kubernetes Secret manifests from structured data instead of string interpolation.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_secret.ml:43-58` renders Secret YAML with
`Printf.sprintf` and raw `namespace`, `key`, and `value` strings. `yaml_quote`
uses `String.escaped`, which is not a general YAML emitter.

**Goal:** Use structured YAML/JSON construction or a shared manifest renderer for
Secret manifests.

**Acceptance criteria:**

- Build Secret manifests from a typed record and a YAML-safe emitter.
- Reuse existing manifest helpers where possible.
- Add tests for values containing quotes, backslashes, and newlines.

Completion: Kubernetes Secret manifests are now rendered from a typed internal
record using a scoped YAML-safe scalar emitter for `data` and `stringData`.
Focused tests cover quotes, backslashes, and newlines, and the affected secret
build/tests pass. No baseline changes accepted.
