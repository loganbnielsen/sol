---
id: CODEX_STYLE_AUDIT-081
type: refactor
severity: medium
source: internal/pipeline/audits/STYLE_AUDIT.md
premise: '! rg -q "List.assoc component" cli/lib/local/sol_cli_local_platform.ml'
---

Key the local infra components by a variant, not a string with a raising lookup

**Depends on:** None.

**Problem.** `cli/lib/local/sol_cli_local_platform.ml` models the six local
infra components as bare strings and looks them up by association:

- `:9` — `let components = [ "redpanda"; "postgresql"; "loki"; "grafana"; "tempo"; "prometheus" ]`
- `:4` — `component_values : (string * string) list`
- `:29` — `let values_of assets component = List.assoc component assets.component_values`

`values_of` raises `Not_found`, and every caller (`:81,95,109,118,140,155`)
passes a string literal that must be spelled exactly as in the `components`
list. Renaming a component in one place, or a typo at a call site, is a runtime
`Not_found` with no message, and nothing ties `components` to the callers. The
set is finite and known, so the compiler can hold it.

**Goal.** A `component` variant (`Redpanda | Postgresql | Loki | Grafana |
Tempo | Prometheus`) with `all` and `name : component -> string`, and a
lookup that cannot fail — either `component_values : (component * string) list`
with `List.assoc` over the variant, or a total `values_of` returning
`(string, string) result` with the missing name in the message. The platform
asset layer still takes the lowercase name, so `name` is applied exactly at
that boundary.

**Acceptance criteria:**

- No `List.assoc` (raising form) remains in `sol_cli_local_platform.ml`.
- The six component names appear once, in the `name` function.
- Adding a component to `all` without a `name` arm does not compile.
- `sol local up`'s release selection (`releases`, `endpoints`) builds the same
  releases with the same `values_yaml`; the existing inline tests pass.
- Full `dune build`; `dune fmt` clean.
