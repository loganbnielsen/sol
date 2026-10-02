---
id: CODEX_STYLE_AUDIT-082
type: refactor
severity: medium
source: internal/pipeline/audits/STYLE_AUDIT.md
premise: '! rg -q "exception _ ->" cli/lib/deploy/sol_cli_contract.ml'
---

Decode the declared contract into a typed value instead of printing JSON by hand

**Depends on:** None.

**Problem.** `cli/lib/deploy/sol_cli_contract.ml:41` `print_declared_contract`
walks the contract JSON with `Yojson.Safe.from_string`, `List.assoc_opt` and two
local field accessors:

- `:45` `string_field` and `:50` `int_field` return the literal `"?"` when a
  field is the wrong shape or absent, so a schema change prints a plausible
  `module ?  topic ?  partitions ?` line rather than reporting a problem.
- `:69` ends the function with `exception _ -> ()`, swallowing any parse
  error: the whole "Contract (declared)" block silently disappears.

The module is the CLI's contract reporter, and the repo already has the
boundary for this — `Sol_cli_json` (`decode ~what`, `field`, `string`, `int`,
`list`, `require`) — plus the `operation → typed outcome → renderer` split the
style checklist asks for. The decode decision and the printing are currently
one function.

**Goal.** Decode the projection into a small typed value
(`declared_contract = { events : declared_event list }`,
`declared_event = { module_name : string; topic : string; partitions : int }`,
or the same with `optional` fields), return `(declared_contract, string) result`
from a `decode_declared_contract : string -> ...`, and let
`print_declared_contract` render that value. On a malformed projection the
caller reports the reason with `Sol_cli_report.warn` and skips the block, as
`plan_report` already does for a missing registry.

**Acceptance criteria:**

- `rg -n "exception _ ->" cli/lib/deploy/sol_cli_contract.ml` returns nothing.
- `rg -n '\"\?\"' cli/lib/deploy/sol_cli_contract.ml` returns nothing.
- A new test covers (a) a well-formed projection rendering every event, and
  (b) a malformed projection producing an `Error`/warning instead of silence.
- `sol deploy` still prints the declared-contract block for a workspace with a
  `contract/` projection; the existing inline tests pass.
- Full `dune build`; `dune fmt` clean.
