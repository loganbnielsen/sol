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
