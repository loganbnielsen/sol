---
id: REFAC-128
type: refactor
severity: medium
title: sol new scaffolds from a template tree in Sol's assets, not from OCaml string literals
source: operator review (2026-09-26, sol-logan-comments), cli/lib/workspace/sol_cli_cmd_new.ml
---

**Depends on:** None.

## The problem

The operator, on `Sol_cli_cmd_new.new_workspace`: "lots of hard coding throughout this file. Including 31 file generated lol. Seems like this should be a more dynamic / flexible process?"

Every file `sol new` generates is an OCaml string in `cli/lib/base/sol_cli_scaffold_templates.ml` (1278 lines on origin/main, 2026-09-26). `sol_cli_cmd_new.ml` writes them with 20 `write ~path` calls and hand-built substitution lists. Consequences:

- Changing a generated file means editing OCaml strings, with escaping, rather than the file itself.
- A template can't be linted or built as what it is. A `dune` file or `.ml` inside a string is never checked until a scaffold test runs.
- The file list lives in code, so adding a generated file is a code change in several places.
- The language dimension (DEC-022) has to be threaded by hand. TypeScript scaffolding needs its own tree.

## Remediation

- Move the templates to files under `platform/shared/templates/<kind>/…`, where `<kind>` is `workspace`, `svc`, `worker`, `fn` or `event`, laid out exactly as they are generated. This follows DEC-046 rule 2: `platform/` holds what the CLI drives. They are resolved through `Sol_cli_platform_assets`, as a release bundle already does for other assets (DEC-049).
- `sol new <kind>` copies the tree, substituting `{{name}}`-style placeholders from one typed set of variables per kind, and applies a small, declared set of per-file rules (for example "keep an existing `sol.toml`"). The OCaml keeps the orchestration and validation; the content lives in the files.
- Paths are templates too (`app/{{domain}}/{{name}}_svc/…`), so the file list is the directory tree.
- The existing scaffold tests keep passing unchanged. They are the contract for what a new workspace contains.

## Acceptance criteria

- `sol_cli_scaffold_templates.ml` is gone, or holds only substitution logic. `git grep -c 'write ~path' -- cli/lib/workspace/sol_cli_cmd_new.ml` is at most the generic copy loop.
- Each template file is checked as its kind where it can be. For example, the generated workspace builds in the existing scaffold smoke.
- A release bundle includes the templates, and `sol assets` checks them.
- The scaffolded workspace is unchanged: the scaffold tests pass as they are, and the notes include a byte-diff of a generated workspace before and after.
- Demo/example: the scaffolded workspace *is* the demo; state that it is unchanged.
- Language parity: note what a TypeScript template tree would need (see FEAT-102).

## Completion notes

**The templates are files.** 52 of them under
`platform/shared/templates/{workspace,svc,worker,fn,event}/`, laid out exactly as
generated — `{{basename}}.opam`, `lib/{{name}}_worker.ml` and
`events/{{team}}/{{name}}.ml` are templated *paths*, so the file list is the
directory tree. `cli/lib/base/sol_cli_scaffold_templates.ml` is deleted;
`git grep -c 'write ~path' -- cli/lib/workspace/sol_cli_cmd_new.ml` is **0**. What
stays in OCaml is one typed variable set per kind, the destination, and two declared
per-file rules (`event`: append the module to an existing `(modules ...)`, keep an
existing `sol.toml`). The content was extracted **verbatim** from the
`{tpl|…|tpl}` literals, so it is exact by construction rather than by inverse
substitution.

**One non-obvious constraint, verified both ways.** Ten templates are *named* `dune`
and contain templates, and the root `dune-project` covers the whole repository — so
`dune build` read them and failed with `Error: "{{lib}}" is an invalid library name`.
`platform/shared/templates/dune` declares the five kinds `data_only_dirs`; removing
that stanza reproduces the error and restoring it returns `dune rules` to 0. It also
keeps `dune fmt` off the template `.ml` files.

**Byte-diff before/after.** `cli/bin/main.exe` was built from the *same* commit in a
pristine checkout, then a workspace plus `new svc`, `new worker`, `new fn` and
`new event` (which exercises the `(modules Charged Refunded)` patch) were generated
with both binaries: **44 files each, `diff -r` reports no differences**.

**Tests.** `test_scaffold` 49 cases, 47 pass. `existing_files 6/7` ("scaffold actually
compiles", "bare fn library compiles") fail **identically on unmodified `origin/main`
in this machine's switch** — the generated workspace needs the framework libraries
installed (`prepare-framework-deps.sh`) and this switch has no `kafka-eio-service`
(`Library "kafka-eio-service" not found`); CI installs them. `test_toml_keys` 13/13.
The two test files changed mechanically: the expectations are the same bytes, now read
from the tree (`tpl ~kind:…`) instead of from the deleted module.

**Assets.** `Sol_cli_platform_assets.templates_root` resolves the tree; `sol assets`
reports `ok templates workspace 31 files`, `svc 6`, `worker 6`, `fn 6`, `event 3`,
through the same walk the command runs. `build-release-bundle.sh` ships every tracked
file under `platform/`, so the bundle carries the templates with no change to it, and
`smoke_installed_release.sh` exercises that through `sol assets`.

**Also checked:** `dune build` clean; `internal/ci/check_ocamlformat.sh --all` clean;
`check_platform_assets_owner.sh`, `check_workflow_paths.sh` and
`check_platform_component_drift.sh` pass.

**Demo/example:** the scaffolded workspace *is* the demo, and it is byte-identical
above; `examples/pluto` and the tutorial are untouched.

**Language parity (DEC-022):** a TypeScript tree is another kind directory
(`templates/typescript/…`, selected by `sol new --language`, FEAT-102). The engine keys
everything by kind and the per-file rules are language-neutral; only the present
tree's content is OCaml-specific.
