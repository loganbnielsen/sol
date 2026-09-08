# Contributor Map

This map points contributors to the source of truth for common changes. Sol is
a framework: intent should enter through typed models, commands, templates, or
docs, then flow to generated artifacts. Generated YAML, shell calls, and
workflow outputs are not ownership boundaries.

For audit-oriented work, use these workflows as the entry points:

- [`/style-audit`](../../pipeline/tickets/)
  for repository style and consistency work. This worktree does not currently
  track `docs/audits/STYLE_AUDIT.md`; style-audit tickets identify that source
  when the checklist is present.
- [`/audit`](../audits/AUDIT.md) for product and implementation correctness
  checks.
- [`/scaffold-audit`](../audits/SCAFFOLD_AUDIT.md) for generated workspace and
  service contract checks.
- [`/e2e`](../../examples/local-demo/test/test_e2e.ml) for end-to-end local
  workflow verification.
  [`cli/platform/local/scripts/run_tests.sh`](../../cli/platform/local/scripts/run_tests.sh)
  is the broader local test runner reference.

## Command Changes

Command parsing and user-facing CLI behavior live in `cli/sol/bin/`. Shared
command implementation belongs in `cli/sol/lib/`, especially when more than one
command needs the same behavior. `devtools/soldev/` is for internal repository and
ticket workflow tooling, not customer-facing `sol` commands.

Extend commands by adding typed options, shared library functions, and tests in
`cli/sol/test/`. Keep command modules thin enough that behavior can be tested
without invoking a full terminal workflow.

Do not add raw shell commands through `Sys.command`, ad hoc `Unix.system`, or
inline shell pipelines to new command logic. Use the existing shell/process
helpers or add a narrow helper that makes command execution explicit, testable,
and consistently reported.

## Deployment Behavior

Deployment intent belongs in the typed deployment pipeline:

```text
workspace scan -> environment resolution -> deployment plan -> executor
```

The main owners are `Sol_cli_workspace_scan`, `Sol_cli_env_target`,
`Sol_cli_deployment_plan`, and `Sol_cli_executor`. Hosted behavior belongs behind `Sol_cli_hosted_executor` and
the hosted model/control-plane modules. The architecture direction is documented
in `docs/architecture/PRODUCT_ARCHITECTURE.md`.

Extend deployment by adding fields to the typed plan, environment resolution,
or executor interfaces first. Then render or execute from that plan.

Do not bypass deployment plans by teaching one command to apply bespoke
resources directly. If local, GitOps, customer-cloud, and hosted modes would
need the same intent, put it in the plan instead of only in one executor.

## Manifest Rendering

Kubernetes manifest rendering is owned by `cli/sol/lib/sol_cli_manifest.ml`,
`cli/sol/lib/sol_cli_manifest_yaml.ml`, and deployment rendering modules that
consume the deployment plan. Manifests are generated artifacts derived from the
workspace structure, environment target, images, secrets policy, and `sol.toml`
overrides.

Extend manifest behavior by changing the typed manifest/rendering layer and
covering the output in `cli/sol/test/test_manifest_render.ml` or an adjacent
deployment-render test.

Do not edit generated YAML paths directly, commit per-service Kubernetes YAML as
normal source, or patch emitted files as the primary implementation. If a user
needs a new override, model it in `sol.toml`, the deployment plan, or a documented
escape hatch.

## Scaffold Templates

Scaffold commands are owned by `cli/sol/lib/sol_cli_cmd_new.ml`,
`cli/sol/lib/sol_cli_scaffold.ml`, and
`cli/sol/lib/sol_cli_scaffold_templates.ml`. The generated workspace contract is
validated by `docs/audits/SCAFFOLD_AUDIT.md` and tests in
`cli/sol/test/test_scaffold.ml`.

Extend scaffolds by updating the template source, generated file list, and tests
together. Generated READMEs and workflows should teach current `sol` commands
first, with raw platform commands only as advanced or fallback paths.

Do not hand-edit examples or generated output as the only fix for scaffold
problems. Change the scaffold template and let examples follow through the same
contract when they are refreshed.

## Integrations

There is no `integrations/` directory in this repo. Reusable capability
packages are either in-tree under `framework/` (`kafka-eio-service` — Kafka
schema registry + service orchestration, the same kind of app-linked library
as `sol-svc`/`sol-worker`/`sol-fn`) or extracted to standalone opam packages
pinned into this switch (`kafka-eio`, `obs-eio`, `obs-loki-eio`,
`obs-prometheus-eio`, `pg-eio`, `aws-eio` — see `~/Code/CLAUDE.md`'s repo
layout notes). Framework primitives in `framework/sol-svc`, `framework/sol-worker`,
and `framework/sol-fn` compose these into service lifecycles.

Extend an in-tree capability package with a small public interface,
package-local tests, and package docs. Keep customer service code using the
framework primitive rather than importing another service implementation or
reaching across domains.

Do not add cross-package shortcuts that make one backend know about an
unrelated backend's implementation details. Shared contracts should live in the
lowest package that owns the concept.

## Tests

Unit and package tests live beside their owner package in `test/` directories.
CLI behavior is covered in `cli/sol/test/`. End-to-end behavior is represented
by `examples/local-demo/test/test_e2e.ml` and the `/e2e` workflow. Audit
checklists in `docs/audits/` define manual verification expectations.

Extend tests at the same boundary as the behavior being changed. For generated
files, assert the generated contract instead of checking in hand-edited output.
For deployment changes, prefer deployment-plan and render tests before heavier
cluster workflows.

Do not replace missing assertions with broad smoke tests only. Keep the smallest
test that proves the ownership boundary, then use `/e2e` when the change affects
the full local workflow.

## Docs

User-facing docs live in `README.md`, `docs/guides/`, `docs/deployment/`, and
`docs/hosted/`. Architecture and ownership docs live in `docs/architecture/`.
Audit checklists live in `docs/audits/`; dated audit findings belong under
`pipeline/audits/`, not in reusable checklist files.

Extend docs where the reader is already making the relevant decision: quickstart
behavior in `README.md`, walkthroughs in `docs/guides/`, deployment contracts in
`docs/deployment/`, hosting concepts in `docs/hosted/`, and contributor-facing
boundaries here.

Do not document unavailable commands, stale workflow names, or generated YAML as
files users should edit. If docs mention a command, generated file, or guarantee,
verify it against the implementation or mark it as future direction.
