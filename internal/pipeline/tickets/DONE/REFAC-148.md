---
id: REFAC-148
type: refactor
severity: low
title: Propagate unchanged Result errors instead of matching them by hand
source: Logan code review (2026-09-27), generalized from cmd_assets template planning
---

Propagate unchanged `Result` errors instead of matching them by hand

**Depends on:** None.

**Premise verified (2026-09-27):**
`rg --pcre2 -n -U '\| Error ([a-zA-Z_][a-zA-Z0-9_]*) -> Error \1' --glob '*.ml' cli framework examples internal`
finds 55 sites on `origin/main` at `52c01e21`. Positive controls include
`cli/bin/cmd_assets.ml:80`, `cli/lib/workspace/sol_cli_toml.ml:88`, and
`framework/ocaml/kafka-eio-service/lib/kafka_service_retry_topics.ml:67`.

## The principle

When a match does nothing with `Error e` except return the same `Error e`, propagate it
with `let*`, `Result.bind`, or an existing Result combinator. The remaining code should
express only the next domain decision. This is OCaml's equivalent of chaining a
fallible computation: error forwarding is plumbing, not business logic.

Do not mechanically rewrite a match whose error type changes, whose success path is not
sequential, or whose explicit branches make ownership clearer.

## Remediation

- Add the rule to `CONTRIBUTING.md` beside `Result.Syntax`.
- Manually review all 55 seeds across production code, examples, and copied templates;
  use the search only as a candidate list.
- Replace high-confidence unchanged-error forwarding with a linear Result pipeline.
- Keep examples and scaffold templates aligned when either teaches the affected shape.

## Acceptance criteria

- Production, example, and scaffold code contains no manual unchanged-error forwarding
  where `let*` or an existing Result combinator makes the next domain decision clearer.
- Every retained seed is named in completion notes with the reason its explicit match is
  clearer or semantically necessary.
- The contributing convention includes one before/after example and warns against
  changing error types accidentally.
- Focused tests cover any rewritten branch that adds domain validation after the bind.
- Demo/example and language-parity impact are recorded per changed site.

## Implementation evidence (2026-09-28)

- Reverified the 55 identity-error seeds at `77fbfa61` with the discovery command,
  then added `platform/` to include copied scaffold code. Positive controls remain
  `get_if_present`, `create_idempotent`, and `verify_whoami_shape`; these have deliberate
  recovery/error conversion rather than simple sequential forwarding.
- Manually reviewed CLI commands and all six CLI library folders, framework packages,
  examples/Pluto and copied scaffolds, and internal tooling. Replaced plumbing in
  filesystem/scaffold traversal, TOML parsing, target/destination resolution, factory
  planning, release storage/validation/retention, boundary leases, rollback discovery,
  Terraform report/plan handoffs, AWS preparation validation/access/observation,
  status HTTP validation, local deployment, schema checks, topic provisioning,
  retry metadata/publication, function responses, and leased-job decode/dispatch.
- Retained `Sol_cli_kubectl.get_if_present`: NotFound becomes absence, other failures
  remain errors. Retained `Sol_cli_manifest.create_idempotent`: AlreadyExists succeeds.
  Retained `Sol_cli_aws_cluster.verify_whoami_shape`: the explicit nested-result arms
  distinguish access setup from process execution and enrich nonzero diagnostics.
  `cmd_assets.template_checks` is handled by REFAC-144, not duplicated here.
- Cleanup remains after the captured deployment/consumer result, attempt recording
  remains before propagating a deployment failure, and acknowledgements still happen
  only after successful publication. No error types or runtime contracts changed.
- Added contributing guidance with before/after composition and recovery/error-type
  cautions. No new operator, abstraction, dependency, or public API.
- Focused CLI release store/retention/validation, boundary lease, factory, destination,
  observability URL, config, Terraform plan, status, rollback, cloud apply/destroy,
  TOML and workspace registration tests pass. Kafka service (39), job policy (8),
  and function lifecycle/metrics (10) tests pass; builds, formatting and the 672-file
  no-comments guard pass. Scaffold's two isolated-build cases initially lacked
  installed framework packages; the documented dependency helper installed them,
  then all 52 scaffold tests passed. All 814 ticket files validate.
- Demo/example: the inspected examples and copied templates have no qualifying
  unchanged-error forwarding to change; scaffold traversal internals are covered
  by scaffold tests. No application-facing API or example usage changed.
- Language parity: no impact at any changed site; Result composition preserves the
  existing language-neutral deployment, security, retry/DLQ and job contracts.
