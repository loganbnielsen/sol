---
id: CODEX_STYLE_AUDIT-045
branch: CODEX_STYLE_AUDIT-045/typed-plan-identifiers
worktree: ../sun-CODEX_STYLE_AUDIT-045-typed-plan-identifiers
type: refactor
severity: medium
source: style audit
---

Introduce newtypes for deployment-plan topics, migrations, schema subjects, and consumer groups.

**Depends on:** CODEX_STYLE_AUDIT-040.

**Problem:** `Sun_cli_deployment_plan.t` stores `topics`, `migrations`,
`schema_subjects`, and `consumer_groups` as `string list`. These lists are not
interchangeable domains, but the type system treats them identically.

**Goal:** Prevent accidental mixing of deployment artifact identifiers.

**Acceptance criteria:**

- Add small wrapper types with constructors/validators for each identifier.
- Update workspace scan discovery functions to return those types.
- Keep JSON output as strings.

## Review — automated checks passed
All 4 newtypes (Topic_name, Migration_file, Schema_subject, Consumer_group) are defined in Sun_cli_plan_ids with of_string/to_string; Sun_cli_deployment_plan.t fields are typed; to_json calls to_string before `String; discovery functions return typed lists; tests cover rejection of empty strings, non-.sql migrations, overlong/invalid-char topics; cmd_deploy.ml and cmd_up.ml call to_string at the string-boundary callsites; no wrapped true; project/tickets/ untouched; build and tests pass.
