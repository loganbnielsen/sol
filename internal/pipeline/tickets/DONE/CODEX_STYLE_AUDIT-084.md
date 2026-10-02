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

## Completion (2026-10-02)

- **Premise re-verified** at `origin/main` `c877efa5`: `aws` was a single ~256-line record literal and `gcp` ~160, with the probes, vars and identity contracts as inline lambdas and no visible field structure.
- **Fix, by concern rather than by field.** The multi-line pieces are now named, explicitly typed values: `aws_backend_config`, `aws_cluster_access_role_arn`, `aws_installation_probes`, `aws_installation_backend`, `aws_installation_vars`, `aws_own_vars`, `aws_root_declared_vars`, `aws_destroy_guard_vars`, `aws_installation_zone_lookup`, `aws_installation_identity_contracts`, and `gcp_installation_probes`, `gcp_installation_vars`, `gcp_own_vars`, `gcp_installation_zone_lookup`. The zone probes are their own concern in `aws_zone_probes` / `gcp_zone_probes`. Short scalars and lists (`platform_storage`, `state_locking`, `sol_keys`, `guarded_addresses`, `cloud_ready_expectation`, …) stay inline — this is not a mechanical hoist of all 32 fields.
- **Annotations where they carry the contract.** Every extracted value is annotated (a record-typed lambda parameter outside the record literal has no other source of its type), and both records are written `let aws : t =` / `let gcp : t =`, so a missing or mistyped field fails to compile.
- **One equivalence, recorded.** In the `Service_zone { domain; ownership }` arm the original re-matched `configuration.zone` to append `[ public_delegation_probe domain ]`; the arm already knows the zone is a `Service_zone`, so the extracted helper appends the probe directly. Same probes, in the same order.
- **Size.** The longest remaining values are `aws_installation_probes` 62, `aws` 66, `gcp_zone_probes` 53 and `gcp` 60 lines: the record literals are now field lists, satisfying the ~60-line guideline.
- **Tests.** `cli/test/inline` (including `test_installation.ml` and `test_open.ml`) passes with no expectation changes, which is the value-preservation check; `cli/lib/cloud/sol_cli_provider_capabilities.mli` is unchanged, so `aws`/`gcp` keep their type.
- Full `dune build`; `dune fmt` clean; all 90 fast guards pass.
- **Demo/example: not applicable** — provider capability data, no app-author surface. **Language parity: no impact.**
