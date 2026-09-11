---
id: CODEX_STYLE_AUDIT-001
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-001/typed-helm-values
worktree: ../sun-CODEX-001
---

Replace Helm `set_val` string payloads with typed chart values.

**Depends on:** none.

**Problem:** `cli/sun/bin/cmd_dev.ml:23` has a `LOGAN:` note calling out that
`type set_val = Val of string | Str of string` encodes booleans, floats, sizes,
and raw strings through unvalidated string payloads. The call sites around
`cmd_dev.ml:83-97` pass `"false"`, `"true"`, `"1.5"`, `"1Gi"`, and ports as
opaque strings, so typo and quoting mistakes compile.

**Goal:** Make Helm chart values self-documenting and type-checked before
rendering shell flags.

**Acceptance criteria:**

- Replace `Val of string` with finite constructors such as `Bool`, `Int`,
  `Float`, `Quantity`, or a similarly explicit domain model.
- Keep a separate constructor for values that must be forced through
  `--set-string`.
- Update `helm_install` rendering so booleans use `string_of_bool` instead of
  hand-written `"true"` / `"false"` strings.
- Add or update a small test/helper assertion for representative rendered Helm
  flags.

## Review — automated checks passed
helm_val type and render_helm_flag correctly promoted to Sun_cli_manifest; cmd_dev.ml local type removed; all four test cases present; build clean; no ticket directory changes.
