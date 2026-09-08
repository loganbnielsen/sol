---
id: CODE_LAYER-006
type: bug
severity: medium
source: project/audits/2026-09-06_code_layer_audit.md
branch: CODE_LAYER-006/shared-alloy-config
worktree: ../sun-CODE_LAYER-006-shared-alloy-config
pr: https://github.com/loganbnielsen/sun/pull/127
---

**Depends on:** None.

## Problem

`Sun_cli_dev_observability.alloy_config_river` (an OCaml string literal in
`cli/sun/lib/sun_cli_dev_observability.ml`) and
`platform/infra/base/alloy/logs.alloy.tftpl` (a Terraform `templatefile`)
both hard-code the same Alloy River log-shipping config: the
`discovery.kubernetes` pod source, the taxonomy-label `discovery.relabel`
rules (workspace/domain/service/primitive/release), `loki.source.kubernetes`,
and `loki.write`. The OCaml file's own comment admits this is a manual
process: "keep this in sync by hand with the .tftpl if either changes --
Terraform's HCL template language has no OCaml equivalent to share the
source with directly."

Read side by side, the two are currently equivalent for the local/no-auth
case. But nothing enforces that going forward — the next taxonomy label
added, Alloy version bump, or push-target change can land in one file and
not the other with no compiler or test to catch it, exactly the mechanism
that let BUG-016's Loki drift go unnoticed.

## Goal

One real Alloy config file, not two hand-synchronized copies, so a River
config change can't silently diverge between `sun dev up` and
`platform/infra/base`.

## Remediation

`platform/infra/base/alloy/logs.alloy.tftpl` already parameterizes the two
things that genuinely differ between profiles (`loki_push_url`,
`loki_push_basic_auth_username/password`, and the taxonomy label list).
`cmd_dev.ml`'s local case is just that template with the in-cluster Loki URL
and no basic auth. Have `cmd_dev.ml` read
`platform/infra/base/alloy/logs.alloy.tftpl` directly (resolving the Sun
monorepo root the same way `cmd_cloud_tf.ml`'s `resolve_sun_home` /
`Sun_cli_cmd_new.infer_sun_home` already does) and perform the same
`%{ for }`/`%{ if }` substitution Terraform does — or, if that's not worth
building, extract the literal River text into one shared file under
`platform/infra/base/alloy/` that both `main.tf`'s `templatefile` and
`cmd_dev.ml`'s file read consume, with `cmd_dev.ml` passing its own
local-profile values (in-cluster Loki URL, empty basic auth, the fixed
taxonomy label list already in `Sun_cli_manifest_yaml.render_taxonomy_labels`).

Delete `Sun_cli_dev_observability.alloy_config_river` once `cmd_dev.ml` reads
the shared file — do not keep both as a fallback.

## Acceptance criteria

- Only one file contains the actual Alloy River config text; both `sun dev
  up` and `platform/infra/base/main.tf`'s `helm_release.alloy` derive their
  rendered config from it.
- `Sun_cli_dev_observability.alloy_config_river` (the OCaml string literal)
  no longer exists.
- A fresh `sun dev up` still produces a working Alloy install (`alloy
  validate` or an equivalent live check) with logs flowing to Loki with the
  taxonomy labels attached.
- Focused tests pass in `cli/sun`.

## Perf-gate sign-off (2026-09-06)

Merged (PR #127, commit `215942c`). Third occurrence in one session of
the same false-alarm pattern (CODE_LAYER-009, CODE_LAYER-005): post-merge
gate flagged e2e at 1.922s vs. 1.188s baseline (1.62x, over threshold);
automatic revert failed on a dirty `tools/perf/perf_baseline.json`, so
the merge stands and only the ticket-state transition was blocked.
Immediately re-ran `bash platform/local/scripts/run_tests.sh` with no
other change: e2e came back at 1.188s, exactly the baseline. Signing off
as a flake, not a real regression — moving to DONE.
