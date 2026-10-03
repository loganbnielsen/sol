---
id: INFRA-021
type: feature
severity: medium
title: Select expensive CI jobs by what a change touches
source: FEAT-087's explicit deferral; revisited after INFRA-019/INFRA-020, 2026-09-17
---

**Depends on:** None.

CI classifies a pull request as `docs-only` or `source`. Every source change,
even one touching only the TypeScript demo or only OCaml framework code, runs
both language golden paths (~13 and ~9 minutes) and every Dockerfile smoke.
Choosing jobs by what a change touches saves time on ordinary pull requests.
Reusing old runs (tried in INFRA-019, withdrawn in INFRA-020) only helped in
the rare no-op update case.

FEAT-087 deferred a language-aware classifier until both golden paths existed
and were stable. Both now exist and have passed on recent pull requests, so
that precondition is met.

## Proposed classification

- `docs-only`: unchanged.
- `ocaml`: OCaml framework or example code only. Runs the OCaml golden path
  and OCaml example smokes.
- `typescript`: TypeScript packages or demo only. Runs the TypeScript golden
  path and TypeScript smokes.
- `platform/shared`: CLI, platform, manifests, infrastructure, or anything
  shared by both languages. Runs everything.
- **Fail closed:** anything unknown or mixed, and any change to `.github/` or
  `devtools/ci/`, runs everything.

## Constraints

- The required `test` check must still report on every pull request; never give
  a required check a classification condition.
- Keep the classification defined once, in `devtools/ci/classify-changes.sh`,
  with its semantics pinned by its test.
- The path-to-class mapping must be an explicit allowlist per class. Unlisted
  paths are `platform/shared`.

**Demo/example coverage:** Not applicable; CI internals.

**TypeScript parity:** Neutral by design: each language gets its own golden
path whenever its code changes.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: `internal/ci/classify-changes.sh` still yields only `docs-only|source`; no per-language classification.

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Premise check (2026-10-03, implementation)

Re-verified on this branch's base (`origin/main`, `ea9e11d9`) before implementing:
the base `internal/ci/classify-changes.sh` still printed only `docs-only|source`,
and every job in `.github/workflows/ci.yml` still carried
`needs.classify.outputs.kind != 'docs-only'`. Reproduce:

```text
$ git show origin/main:internal/ci/classify-changes.sh > /tmp/before.sh
$ printf 'framework/ocaml/sol-svc/lib/sol_svc.ml\n' > /tmp/list
$ /tmp/before.sh --files-from /tmp/list
source
$ internal/ci/classify-changes.sh --files-from /tmp/list
ocaml
```

`README.md` printed `docs-only` before and after, so the probe is not trivially
matching everything.

## Completion (2026-10-03)

`internal/ci/classify-changes.sh` now emits `docs-only | ocaml | typescript | source`:

- `ocaml` — `framework/ocaml/**`, `examples/pluto/app/{checkout,comms,payments}/**`,
  `examples/pluto/contract/**`, `examples/pluto/lib/**`,
  `internal/fixtures/{local-demo,venus}/**`.
- `typescript` — `framework/typescript/**`, `examples/pluto/app/demo_ts/**`,
  `platform/shared/templates/{svc-ts,worker-ts}/**`.
- `source` — everything else, including any diff that mixes the two languages and
  any path the allowlist does not name. `.github/**` and `internal/ci/**` are
  explicitly `source`; the `classify` step also normalises an unrecognised value to
  `source`, so a mistake fails closed toward running everything.
- `.md`, `internal/pipeline/tickets/**` and non-generated `docs/**` keep riding the
  `docs-only` path.

`.github/workflows/ci.yml` consumes the class: `golden-path-smoke` and
`example-dockerfile-smoke` skip a `typescript` diff; `golden-path-smoke-ts`,
`ts-tests` and `demo-ts-dockerfile-smoke` skip an `ocaml` diff. `classify`,
`test` and `dockerfile-matrix` are unchanged — the required `test` check still
reports on every non-docs path, and an empty `kind` (classify died) still runs
every job.

**Class naming.** The ticket proposed `platform/shared`; the implementation keeps
the existing `source` name for the fail-closed class. `source` is already what the
workflow and the pre-commit hook treat as "run everything"; renaming it would be
churn with no behavioural gain, and the classes are documented in the workflow
header that consumes them.

## Validation

- `internal/ci/always/test_classify_changes.sh` — 66 expectations hold, 27 of them
  new (13 language-tree, 9 shared/unlisted, 5 mixed-language).
- `internal/tooling/scripts/verify.sh always` — 9/9 members pass.
- `internal/ci/check_workflow_paths.py` and its mutation suite
  `internal/ci/test_workflow_paths.sh` — pass against the edited workflow.
- `internal/ci/check_support_refs.sh`, `check_no_comments.sh` (856 files) and
  `test_no_comments.sh` — pass.
- The workflow parses with PyYAML; every job's effective `if:` was printed and
  checked.

## Scope boundary

The required `test` job is deliberately untouched: it still builds and unit-tests
the OCaml trees for a `typescript`-classified diff. Narrowing it means splitting
the language-neutral static guards from the OCaml build steps inside the one
required check, which is a larger and riskier change than this ticket asks for.

**Demo/example coverage:** Not applicable; CI internals, as the ticket says.

**TypeScript parity:** Neutral by design — each language's golden path still runs
whenever its own code changes.
