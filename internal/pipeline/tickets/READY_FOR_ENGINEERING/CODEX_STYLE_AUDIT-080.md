---
id: CODEX_STYLE_AUDIT-080
type: refactor
severity: low
source: internal/pipeline/audits/STYLE_AUDIT.md
premise: '! rg -q "has_prefix" cli/lib/base/sol_cli_alerting.ml'
---

One substring toolkit: stop re-deriving prefix and marker scans

**Depends on:** None.

**Problem.** The same two operations are hand-written all over the CLI:
"does this string start with this prefix" and "cut this string at this
needle". `String.starts_with` exists in this toolchain and is already used in
four places (`sol_cli_toml.ml:466`, `sol_cli_release_inspection.ml:179`,
`sol_cli_terraform_workdir.ml:41`, `soldev_cleanup.ml:37`), but the manual form
keeps being re-derived:

- `cli/lib/base/sol_cli_alerting.ml:5` — `has_prefix` is a private
  `String.length`/`String.sub` reimplementation of `String.starts_with`, and
  `url_is_routable` (`:10`) computes `scheme_len` by calling it three times.
- `cli/lib/workspace/sol_cli_config.ml:251` — `yaml_problem` strips
  `"error calling parser: "` with a manual length test, then scans for
  `" character "` with a hand-rolled recursive `find`.
- `cli/lib/kube/sol_cli_kubectl.ml:52` — `status_reason` re-derives the same
  recursive scan for `"Error from server ("` before `String.index_from_opt`.
- `cli/lib/cloud/sol_cli_provider_registry.ml:48` — `state_holds_any` inlines
  the length test per prefix.
- `cli/lib/cloud/sol_cli_provider_capabilities.ml:170` — `role_name`'s `after`
  is a third copy of the recursive scan, for `":role/"`.
- `cli/lib/base/sol_cli_image_ref.ml:19`, `cli/lib/deploy/sol_cli_rollback.ml:785`,
  `cli/bin/cmd_uninstall.ml:60`, `cli/lib/cloud/sol_cli_installation_stage.ml:38`
  — the same length-test-then-`String.sub` prefix check.
- `internal/tooling/soldev/lib/soldev_merge.ml:305,326` and
  `internal/tooling/soldev/lib/soldev_ticket.ml:125,137` — two private copies
  each of `starts_with` and `contains_substring`, in two modules of one package.

`cli/lib/base/sol_cli_string.ml` is the natural home: it already owns
`contains` and is depended on by every `cli/lib` domain. `soldev` does not
depend on `sol_cli_string` (`internal/tooling/soldev/lib/dune` lists only
`sol_process yojson yaml`), so it needs its own single copy rather than a
cross-package dependency.

**Goal.** One declaration per package for prefix tests and marker scans:
`String.starts_with` where that is all that is needed, and small named helpers
on `Sol_cli_string` (`strip_prefix_opt`, `before_opt`) for the cut-at-a-needle
cases; the two `soldev` copies collapse to one module. Each call site keeps its
own semantics — this is a consolidation, not a behaviour change.

**Acceptance criteria:**

- `rg -n "has_prefix" cli/` returns nothing, and `url_is_routable` reads one
  `String.starts_with` decision instead of three calls to a private helper.
- `yaml_problem`, `status_reason`, `state_holds_any` and `role_name` no longer
  contain a recursive `String.sub` scan; each uses a named `Sol_cli_string`
  helper or `String.starts_with`.
- `rg -n "let starts_with|let contains_substring" internal/tooling/soldev/`
  shows each helper exactly once.
- `yaml_problem`'s existing tests (malformed-YAML messages) still pass, and a
  new case pins the `" character "` cut so the moved scan keeps its behaviour.
- Full `dune build`; `dune fmt` clean; `cli/test/inline` passes.
