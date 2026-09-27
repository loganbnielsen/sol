---
id: REFAC-131
type: refactor
severity: high
title: Build Kubernetes manifests as YAML values, not sprintf templates -- every scalar goes through one emitter
source: pattern audit of the REFAC-104..130 series (2026-09-26); REFAC-106 parses YAML with a library but manifests are still written as text
premise: "rg -q 'yaml_to_string' cli/lib/workspace/sol_cli_manifest_yaml.ml"
---

**Depends on:** None.

## The problem

REFAC-106 replaced the hand-written sol.yml *parser* with `ocaml-yaml`, but every manifest Sol *writes* is still a `{|…|}` template filled by `Printf.sprintf`. `rg -c '%s' cli/lib/workspace/sol_cli_manifest_yaml.ml` (2026-09-26) counts well over a hundred interpolations in 1,175 lines, and no value is escaped:

```ocaml
(* cli/lib/workspace/sol_cli_manifest_yaml.ml:54 *)
let render_env_block env =
  String.concat "\n" (List.map (fun (k, v) -> f "  %s: \"%s\"" k v) env)
```

A `sol.toml` env value containing `"`, `\` or a newline produces YAML that is either invalid or says something other than what was written (a value ending `"\n  OTHER: "x` injects a key). Labels, annotations and hostnames are rendered the same way. Plain-style interpolations (`name: %s`) have the dual problem: a value such as `true`, `null` or `1.10` changes type when Kubernetes reads it.

The same shape is repeated wherever the CLI writes YAML: the ConfigMaps in `sol_cli_dev_observability.ml` and the other `apiVersion:` literals in `cli/lib`.

## Remediation

- One emitter module in `cli/lib/base` over `Yaml.yaml` (scalar styles are controllable there; `Yaml.value` would drop them): constructors for a map, a list, an int, a bool, and two string forms --
  - `string`: plain style when the text cannot be read back as anything but a string, double-quoted otherwise (booleans, nulls, numbers, anything with YAML indicators);
  - `quoted`: always double-quoted, for the fields the templates quote today (env values, labels, annotations), so their output stays recognisable.
  Multi-document output is one function.
- Every manifest builder returns a value; rendering to text happens once. No `Printf.sprintf` builds YAML anywhere in `cli/lib`.
- A CI guard fails on an `apiVersion:` string literal in `cli/lib` outside the emitter's tests, with a mutation test (positive control).

## Acceptance criteria

- Tests: an env value, label and annotation containing `"`, `\`, a newline and `: ` round-trip through `Yaml.of_string` to the exact original string; values `true`, `null`, `012`, `1.10` stay strings.
- The existing `test_manifest_render` suites pass. Any assertion that pinned template-only formatting (indentation of a nested list, say) is updated and listed in the completion notes.
- The rendered pluto manifests (`sol up local --dry-run` / `sol deploy --emit-to`) are shown before and after, and every document still applies with `kubectl apply --dry-run=client` or parses with `Yaml.of_string` to the same value.
- The guard exists, runs in CI, and its mutation test fails on a planted literal.
- Demo/example: the pluto manifests are the demo; state that they are semantically unchanged.
- Language parity: no impact (rendering is language-neutral).
