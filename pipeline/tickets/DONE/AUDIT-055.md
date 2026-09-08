---
id: AUDIT-055
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-055/scaffold-template-organization
worktree: /home/lbendtly/Code/sun-AUDIT-055-scaffold-template-organization

---

Move scaffold templates out of the `sun new` command implementation

**Depends on:** None.

**Description:** `cli/sun/lib/sun_cli_cmd_new.ml` is over 1,100 lines and mixes command implementation with large inline templates for README content, GitHub Actions workflows, Dockerfiles, event modules, service modules, worker modules, migrations, and tests.

**Impact:** The entry point for `sun new` is hard to follow because the orchestration logic is buried among generated artifact bodies. Reviewing generated-workspace changes is noisy, and similar template updates require editing a large command module instead of focused template files. This also makes it harder to add golden fixture tests for generated output.

**Remediation:**

1. Move generated artifact bodies into template files under a dedicated directory, or into smaller modules grouped by artifact type.
2. Keep `Sun_cli_cmd_new` focused on argument parsing, workspace shape, and calls into a scaffold renderer.
3. Preserve existing substitution behavior or replace it with a small typed template renderer.
4. Add golden tests for the generated workspace files that are most likely to regress: CI workflows, Dockerfiles, service main files, worker main files, and `test/dune`.

**Acceptance criteria:**

- `Sun_cli_cmd_new` no longer contains large inline CI/Docker/app source templates.
- Generated workspace output is byte-for-byte equivalent where behavior is not intentionally changed.
- Existing scaffold tests pass.
- New golden tests make generated artifact diffs reviewable without reading a 1,100-line command module.

## Review — automated checks passed
Templates extracted to Sun_cli_scaffold_templates, Sun_cli_cmd_new reduced to 292 lines, all 27 golden and scaffold tests pass, no project/tickets touched, wrapped false confirmed.
