---
id: REFAC-106
type: refactor
severity: medium
title: Replace the hand-written sol.yml parser with a YAML library and a strict decoder
source: operator decision (2026-09-26), while implementing FEAT-100
premise: "rg -q 'Yaml.yaml_of_string' cli/lib/workspace/sol_cli_config.ml"
---

**Depends on:** None.

## The problem

`Sol_cli_config.load` is a hand-written, line-oriented parser: an indentation-position state machine that accepts one document shape. No decision explains it; it predates the history baseline, and the only written rationale is ADR 0001's "the OCaml side has no YAML dependency today". It rejects valid YAML (flow maps, quoted keys, multi-line values) with "unsupported sol.yml syntax", and every new shape needs more hand-written state. FEAT-100's nested environments file would have needed a de-indent-and-re-feed layer on top of it.

## Remediation

- Parse with the `yaml` package (ocaml-yaml, libyaml; `opam show yaml --field=depexts` is empty, so no OS package).
- Decode `Yaml.yaml` rather than `Yaml.value`, because a scalar there keeps the exact text the user wrote. Values stay strings exactly as before (`1.10`, `012`, account ids), where the value API would turn them into numbers.
- Keep the key table and every semantic error message: unknown keys, missing values, provider-owned keys (REFAC-098), unsupported providers, duplicates, integers, booleans and languages.
- Errors are key-scoped. A YAML syntax error names its line, recovered from the event stream, because libyaml's own message has no usable position.
- Add `yaml` to `sol.opam` and to `cli/lib/workspace/dune`.

## Acceptance criteria

- Every existing `sol.yml` and target file in the repository loads with identical values.
- The existing config tests pass, except those that pinned the old parser's own quirks, which are updated and listed in the completion notes.
- New tests: flow maps parse; numeric-looking text is preserved; a duplicate key fails; a syntax error names its line.

## Completion notes

- **Premise verified (2026-09-26, `origin/main` after REFAC-104):** `load` read the file line by line with `input_line` and rejected any shape outside its state machine with "unsupported sol.yml syntax".
- **Implementation.** `Sol_cli_config.load_string ~path text` parses with `Yaml.yaml_of_string` and decodes the tree against the existing `target_key` table. `load path` reads the file and calls it. The text helpers (`strip_comment`, `parse_scalar`, `parse_list`, `split_key_value`, …) and the section state types are removed.
- **Scalars keep their text.** The decoder reads `Yaml.yaml`, not `Yaml.value`. A probe shows `a: 1.10`, `d: 012` and `c: yes` arrive as the scalars `1.10`, `012` and `yes`, so string fields are unchanged and booleans are still strictly `true`/`false`.
- **Errors.**
  - Every semantic message is unchanged, and duplicate keys remain errors with their old wording (`duplicate service`, `duplicate index`, `duplicate target provider box`, `duplicate top-level section`, `duplicate <provider> target field`).
  - YAML syntax errors read `invalid YAML: <libyaml's problem>` and carry a line recovered from `Yaml.Stream`. libyaml's own message says "character 0 position 0". A probe with an unclosed `[` on line 7 reports line 7.
  - `error_to_string` omits `:0` for errors that have no line.
- **Behaviour changes, deliberate:**
  - flow maps and other valid YAML are accepted;
  - key order no longer matters, so `target:` may follow `resources:`;
  - aliases are refused.
- **Tests updated, all pinning the old parser's quirks:**
  - `malformed list fails`, `malformed quoted scalar fails`, `malformed quoted list item fails` and `provider box ends before generic key` now assert an `invalid YAML:` error with a line, because those inputs are not valid YAML;
  - `target after resources fails` became `target after resources parses`.
- **Tests added:**
  - flow maps plus exact text (`cluster_name: 012` and `"1.10"` survive);
  - a duplicate service fails;
  - a syntax error names line 4.
- **Real files.** Every tracked workspace was loaded with the new binary. All four pluto targets resolve (`sol target show`: `pluto-customer`, `pluto-dev`, `pluto-pilot`, `pluto-prod`), and `sol plan` exits 0 in both `examples/pluto` and `internal/fixtures/venus`.
- **Verified:**
  - `dune build` and `dune test cli/test/` pass (0 `[FAIL]`, including the offline lifecycle harness);
  - every `internal/ci/test_*.sh` passes;
  - `check_ocamlformat.sh --all` is clean.
- **Dependency.** `yaml` is added to `sol.opam` (CI installs from it) and to `cli/lib/workspace/dune`. ADR 0001's "no YAML dependency" remark carries a note.
- **Demo/example:** pluto's files are unchanged and load identically. **Language parity (DEC-022):** config parsing is language-neutral; no impact.
