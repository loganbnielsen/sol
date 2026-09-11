---
id: AUDIT-045
type: audit-finding
severity: medium
source: codebase review 2026-06-13
branch: AUDIT-045/deployment-discovery-model
worktree: /home/lbendtly/Code/sun-AUDIT-045-deployment-discovery-model
---

Consolidate workspace discovery into a typed model; topics, schemas, migrations, schedules, and services are discovered by separate ad hoc scanners

**Depends on:** None.

**Description:** Deployment metadata discovery is split across multiple modules, each scanning the filesystem in a different way:

- `cli/sun/lib/sun_cli_manifest.ml` discovers services by walking `app/<domain>/<service>` and inferring primitives from suffixes.
- `cli/sun/lib/sun_cli_manifest.ml` also extracts `-fn` schedules by scanning source files for `schedule = "..."`.
- `cli/sun/lib/sun_cli_deployment_plan.ml` discovers topics by scanning event source files for `let topic_name = "..."`.
- `cli/sun/lib/sun_cli_deployment_plan.ml` discovers schema subjects by walking `events/`.
- `cli/sun/lib/sun_cli_deployment_plan.ml` discovers migrations by listing `db/migrations`.
- `cli/sun/lib/sun_cli_workspace.ml` separately scans every `dune` file for dependency strings to decide which infra `sun dev up` should install.

Each scanner has its own error handling and depth assumptions. Most failures are swallowed and converted to empty lists.

**Impact:** The deployment plan is hard to reason about because there is no single entry point for "what is in this workspace?" Small layout changes can silently remove topics, schema subjects, schedules, migrations, or infra requirements from the plan. This also makes similar patterns harder to abstract: every new capability tends to add another scanner rather than extending a shared workspace model.

**Remediation:**

1. Add a typed workspace inventory module, e.g. `Sun_cli_workspace_model`, that performs one explicit scan from the workspace root and returns:
   - services with domain/name/primitive/paths;
   - event modules, topic names, and schema subjects;
   - migrations and down migrations;
   - function schedules;
   - infra requirements.
2. Replace source-string extraction where possible with generated metadata from scaffolded files or explicit `sun.toml` fields. In particular, move `-fn` schedules and event topic names into typed config or generated metadata rather than parsing OCaml source.
3. Return structured warnings for unreadable directories, malformed metadata, duplicate topics, duplicate schema subjects, and unknown service layouts instead of silently ignoring them.
4. Make `Sun_cli_deployment_plan.of_services`, `sun dev up`, `sun up`, `sun deploy`, `sun status`, and tests consume the same inventory.

**Acceptance criteria:**

- There is one documented workspace inventory entry point used by deployment planning and dev-infra detection.
- Service, topic, schema, migration, and schedule discovery share consistent error reporting.
- Tests cover duplicate topics/schema subjects and malformed schedule/topic metadata.
- Existing scaffolded workspaces produce the same deployment plan after the refactor.

## Review — returned for revision
- `cli/sun/lib/sun_cli_workspace_model.ml:7` — type t is missing 'services' and 'schedules' fields required by the ticket remediation; the inventory does not yet consolidate service discovery (domain/name/primitive/paths) or -fn schedule extraction
- `cli/sun/lib/sun_cli_workspace_model.ml:171` — _mig_warnings is silently discarded in scan; migration warnings are never surfaced, violating the 'consistent error reporting' acceptance criterion
- `cli/sun/bin/cmd_up.ml:0` — cmd_up does not use Sun_cli_workspace_model; acceptance criterion 4 requires sun up to consume the shared inventory
- `cli/sun/bin/cmd_deploy.ml:0` — cmd_deploy does not use Sun_cli_workspace_model; acceptance criterion 4 requires sun deploy to consume the shared inventory
- `cli/sun/bin/cmd_status.ml:0` — cmd_status does not use Sun_cli_workspace_model; acceptance criterion 4 requires sun status to consume the shared inventory
- `cli/sun/test/test_workspace_model.ml:0` — no test coverage for malformed schedule metadata; acceptance criterion 3 explicitly requires tests for malformed schedule/topic metadata

## Review — automated checks passed
All six review violations are resolved: type t has services and schedules fields, migration warnings are surfaced, cmd_up/cmd_deploy/cmd_status all use Sun_cli_workspace_model, discover_schedules emits Malformed_metadata for invalid cron, and test_workspace_model.ml has both valid and malformed schedule test cases. Build passes cleanly. project/tickets/ is not touched in the worktree.
