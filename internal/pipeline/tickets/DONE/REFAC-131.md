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

## Completion notes

**Premise verified (2026-09-27, `origin/main` at `cf199c5b`):** `rg -c 'yaml_to_string' cli/lib/workspace/sol_cli_manifest_yaml.ml` → no match; the file built every manifest with `Printf.sprintf` over `{|…|}` templates, `render_env_block` wrote `f "  %s: \"%s\"" k v` unescaped.

- **One emitter.** `Sol_cli_yaml` (`cli/lib/base`, over `ocaml-yaml`'s `Yaml.yaml`, so scalar styles are controlled): `map`, `list`, `int`, `bool`, `string` (plain only when nothing could read it as another type or as syntax -- YAML 1.1 booleans/nulls/numbers, spaces and indicators are quoted), `quoted` (always double-quoted, for env values/labels/annotations as before), `literal` (a whole file carried as a `|` block, exact), `document ?comments`, `render`, `to_string`.
- **Every manifest is a value.** `sol_cli_manifest_yaml.ml`'s sixteen builders return `Sol_cli_yaml.document` (`pvc_docs`, `blue_green_service_docs` return lists, so the `""` filter in the renderer is gone); `render_spec` renders once. The Deployment and Rollout pod templates were two ~150-line copies and are now one `pod_template`. `?config_hash` is required (it was always passed; its `""` default could only hide a missed argument), and `?ingress_host` is an option rather than `""`-means-absent.
- **The other text manifests, codebase-wide:**
  - `sol_cli_dev_observability`: the ConfigMap and Grafana datasource files and the Alloy Helm values. This is where CODE_LAYER-006 had already found a hand-indented block scalar at its key's own indent; the emitter owns indentation now.
  - `cmd_migrate`: the migration ConfigMap and Job, and its private `yaml_dq` escaper, moved into the library as `Sol_cli_manifest.migration_configmap_doc` / `migration_job_doc`, which makes the Job's secretRef a *rendered* test (`test_runtime_secret_identity`) instead of a source grep.
  - `sol_cli_secret`: `render_secret_manifest` and its second private `yaml_quote`.
  - `sol_cli_deployment_state`: a JSON ConfigMap `sprintf`'d with `String.escaped`, which is OCaml escaping -- a non-ASCII byte became decimal `\ddd`, which no JSON reader accepts. Now `Yojson`.
- **NUL.** libyaml takes C strings, so a NUL silently truncated a value (found by the round-trip test). The two boundaries where user text can carry one refuse it by name -- `sol.toml` (TOML can spell `\u0000`) and migration files -- and the emitter's constructors raise `Invalid_argument` rather than truncate.
- **Guard:** `internal/ci/check_manifests_are_values.sh` (no `apiVersion:` / `"apiVersion":` text in `cli/bin`, `cli/lib`) with `test_manifests_are_values.sh` (four cases: value forms and test fixtures pass; a YAML template, a sprintf'd JSON manifest and an escaped-string JSON manifest each fail). Both run in CI.
- **Guards that read the old text, updated:** `check_operator_diagnostics.sh` greps the RoleBinding's `~cluster_role:`/`~group:` arguments (its mutation test gains "another ClusterRole" and "another group"); `check_runtime_secret_identity.sh` checks that `sol migrate` renders through the tested builder.
- **Before/after, pluto.** Both binaries (pre-change `origin/main` and this branch) ran `sol up --dry-run` in `examples/pluto`; every emitted document parsed with PyYAML (YAML 1.1, as Kubernetes reads it): **37 documents each, identical values**, kinds ConfigMap, Deployment, Ingress, Namespace, NetworkPolicy, PodDisruptionBudget, Secret, Service, ServiceAccount.
- **Positive control, same run, with `GREETING = "say \"hi\"\n  INJECTED: \"yes"` added to a pluto `sol.toml`:** the pre-change ConfigMap does not parse (`while parsing a block mapping`); this branch's parses to `data.GREETING == 'say "hi"\n  INJECTED: "yes'` with no `INJECTED` key.
- **Tests:** new `test_yaml.ml` (hostile strings and YAML-1.1 look-alikes round-trip through `string` and `quoted`; plain only where safe; ints/bools typed; literal blocks exact; NUL refused; empty `{}`/`[]`; documents and comments); `test_manifest_render` gains an end-to-end hostile env value and a `yes` label; `test_toml_keys` a NUL refusal. Updated for formatting only: `cpu: 2` is now `cpu: "2"` (a bare `2` is a YAML integer; a quantity accepts the string); the Alloy values tests parse the file and compare its content instead of checking `content: |-` and hand-counting indentation. `dune test cli/ --force`: 0 failures. Format clean.
- **Output formatting changes, deliberately:** nested sequences are emitted at their key's indent (libyaml's block style), an optional section that was absent is absent rather than a blank line, the redacted Secret's comment follows `---`, and literal blocks keep trailing newlines (`|` rather than `|-`, so dashboards are carried byte for byte).
- **Demo/example:** pluto's manifests are semantically unchanged (above).
- **Language parity (DEC-022):** no impact -- rendering is language-neutral.
