---
id: CODEX_STYLE_AUDIT-003
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-003/labeled-cmd-args
worktree: ../sun-CODEX-003
---

Remove boolean traps from CLI command entrypoints.

**Depends on:** none.

**Problem:** Several command `run` functions are called through generated
Cmdliner plumbing with positional booleans whose meaning is not visible at the
call site:

- `cli/sun/bin/cmd_up.ml:38` has `run filter_path dry_run tag confirm_group_change`.
- `cli/sun/bin/cmd_logs.ml:63` has both `_follow : bool` and `no_follow : bool`.
- `cli/sun/bin/cmd_cloud_tf.ml:83` has `cloud_init use_aws use_gcp var_file dry_run`.

**Goal:** Make command invocation shapes self-documenting and prevent swapped
boolean arguments.

**Acceptance criteria:**

- Convert these command functions to labeled arguments and a trailing `()`.
- Replace paired provider booleans with a `provider` variant before entering
  `cloud_init`.
- Replace the logs follow/no-follow pair with one typed mode or one labeled
  boolean.
- Update Cmdliner terms and tests to call the new labeled APIs.

## Review — automated checks passed
All three run functions converted to labeled arguments with correct lambda wrappers in Term expressions; build is clean and diff is confined to cli/sun/bin/
