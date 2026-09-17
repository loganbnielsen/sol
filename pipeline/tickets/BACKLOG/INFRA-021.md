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
- `platform`/`shared`: CLI, platform, manifests, infrastructure, or anything
  shared. Runs everything.
- **Fail closed:** anything unknown or mixed, and any change to `.github/` or
  `devtools/ci/`, runs everything.

## Constraints

- The required `test` check must still report on every pull request; never give
  a required check a classification condition.
- Keep the classification defined once, in `devtools/ci/classify-changes.sh`,
  with its semantics pinned by its test.
- The path-to-class mapping must be an explicit allowlist per class. Unlisted
  paths are `platform`.

**Demo/example coverage:** Not applicable; CI internals.

**TypeScript parity:** Neutral by design: each language gets its own golden
path whenever its code changes.
