---
id: CODEX_STYLE_AUDIT-084
type: refactor
severity: low
source: internal/pipeline/audits/STYLE_AUDIT.md
---

Build the provider capability records from named per-concern values

**Depends on:** None.

**Problem.** `cli/lib/cloud/sol_cli_provider_capabilities.ml` declares the two
provider contracts as two monolithic expressions: `aws` at `:131` runs ~270
lines and `gcp` at `:401` runs ~160, each a single record literal whose fields
are inline lambdas. Inside `aws`'s `installation_probes` field, `role_name`
and its private `after` scanner are defined at `:170-189` in the middle of the
record, so the provider contract cannot be read as a list of fields and one of
its string helpers is buried in a lambda (CODEX_STYLE_AUDIT-080 moves that
scanner to `Sol_cli_string`).

Nothing about the values is wrong; the problem is that the file's unit of
review is one enormous expression, and a reader cannot see where
`backend_config` ends and `installation_probes` begins.

**Goal.** Assemble each provider record from named per-concern values, e.g.
`aws_backend_config`, `aws_cluster_access_role_arn`, `aws_installation_probes`
and a short `let aws = { backend_config = aws_backend_config; ... }`, with the
same for `gcp`. The capability values, keys and probe commands must not change.
The `role_name`/`after` helper becomes a named function (or the shared
`Sol_cli_string` helper from 080) rather than an inline definition inside the
record.

**Acceptance criteria:**

- `aws` and `gcp` are records assembled from named values; no single value in
  the file exceeds ~60 lines.
- The capability values are unchanged: the provider/installation tests
  (`cli/test/inline/test_installation.ml`, `cli/test/inline/test_open.ml`)
  pass without expectation changes.
- `Sol_cli_provider_capabilities.aws` and `.gcp` still have the same type and
  are still what the registry returns for each provider.
- Full `dune build`; `dune fmt` clean.
