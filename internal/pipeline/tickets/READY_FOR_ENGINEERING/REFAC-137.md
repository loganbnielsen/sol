---
id: REFAC-137
type: refactor
severity: low
title: Carry the code conventions into framework/ocaml and soldev -- Result.Syntax, blank env at one boundary, one exit
source: pattern audit of the REFAC-104..130 series (2026-09-26); CONTRIBUTING's conventions were applied to cli/ only
premise: "! rg -q --glob '*.ml' 'let \( let\* \) =' framework internal/tooling"
---

**Depends on:** None.

## The problem

`CONTRIBUTING.md § Code conventions` says each rule "is applied across `cli/`", and it was. The rest of the OCaml in this repository still carries the patterns the CLI removed (counts 2026-09-26):

| Pattern | `framework/ocaml` | `internal/tooling` |
|---|---|---|
| hand-written `let ( let* ) = Result.bind` (a test rule refuses it in `cli/`) | 10 | 0 |
| `Some v when String.trim v <> ""` / `Some ""` at the use site | 7 in lib (`sol-svc/lib/peer.ml`, `service.ml` ×2, `auth_internal.ml`, `sol-fn/lib/fn.ml`, `kafka_service_config.ml` ×2) | 3 (`soldev_ticket.ml` ×2, `soldev_merge.ml`) |
| `exit N` below the entry point | 0 in lib | 21 in `soldev_merge.ml` |

The framework's env reads each decide blank on their own: some trim, some don't, and each builds its own `Sys.getenv_opt` match.

## Remediation

- `Result.Syntax` everywhere; extend the `cli/test/dune` rule (or an `internal/ci` guard) to the whole repository's `.ml`, still exempting the scaffold templates.
- Framework: one env reader per package boundary (a tiny shared `Sol_env`-style helper, or one private function per package if a shared library would create a new dependency edge -- decide by the graph), with blank = unset, used by every framework `Sys.getenv_opt` for a setting. Behaviour for set, unset and blank values is unchanged where it was already "blank = unset"; any site that changes is listed.
- soldev: pipeline steps return `result`; the command entry converts once (REFAC-115's rule).
- soldev: ticket frontmatter is read with the `yaml` library (as REFAC-106 did for `sol.yml`), not split on the first `:` by hand in `soldev_ticket.ml`'s `parse_frontmatter`. Today a quoted value is not unescaped, so a `premise:` probe written with YAML escapes (`"\\("`) runs with doubled backslashes and silently matches nothing -- found while filing this ticket.

## Acceptance criteria

- `rg -n --glob '*.ml' 'let \( let\* \) =' framework internal/tooling cli` finds only the scaffold templates.
- The widened guard fails on a planted hand-written `let*` in `framework/` (positive control).
- `rg -n 'exit [0-9]' internal/tooling/soldev/lib` lists only the entry point, or each remaining site with its reason.
- `dune test framework/` and the soldev tests pass.
- Demo/example: not applicable (internal).
- Language parity (DEC-022): the env-reading contract (blank = unset) is application-facing; the completion notes state whether `@sol-fab/*` treats a blank env value the same way, or record the gap.
