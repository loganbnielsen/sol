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
