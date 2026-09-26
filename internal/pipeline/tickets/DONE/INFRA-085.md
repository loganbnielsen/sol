---
id: INFRA-085
type: feature
severity: medium
title: Application image builds can reuse BuildKit cache (and the CI golden path persists it)
source: measured golden-path CI timings — the first scaffolded OCaml app image costs 297s cold
---

**Depends on:** None.

**Related:** `.github/workflows/ci.yml` (golden-path jobs), `Sol_cli_docker`,
`platform/local/scripts/*` (no), `docs/planning/WORK_SUMMARY.md`.

## The measured problem

On `main @ 85731f78`'s CI run (`golden-path-smoke`, 16m26s):

| Phase | Time |
|---|---|
| Setup (OCaml toolchain, opam pins, framework deps, `sol build`, k3d/kubectl/helm) | ~350s |
| `sol local infra up` (Helm installs) | ~290s |
| **First application image build** | **297s** |
| The next three app images | 2–14s each (they reuse the first one's layers in the same job) |
| Assertions/teardown | ~30s |

A fresh runner has no BuildKit cache of its own, and `sol up` passed no cache flags, so
every run paid the cold dependency layer (`COPY *.opam` then
`opam install --deps-only .`) from scratch.

## What landed

`Sol_cli_docker` gained a cache capability, and CI persists it:

- `SOL_BUILD_CACHE_DIR` names a directory; when set and the buildx plugin is present, the
  build runs as `docker buildx build --load --provenance=false --sbom=false
  --cache-from type=local,src=DIR` (only when the directory already exists, since importing
  a missing one is an error) `--cache-to type=local,dest=DIR,mode=max` — `mode=max`
  because the dependency install happens in the Dockerfile's build stage, and `mode=min`
  would export only the final image's layers.
- With no cache configured, or without buildx, the argv is **byte-identical** to what it
  was before (including the FRIC-018 legacy-builder fallback): the cache is an
  optimization, never a prerequisite.
- CI (`golden-path-smoke`) restores/saves that directory with `actions/cache`, keyed per
  run with a prefix restore, so the entry refreshes and the previous run's cache is what
  gets imported.

The boundary is deliberate: Sol knows a cache *location*; CI knows how a cache survives a
runner.

## Correctness, measured rather than argued

BuildKit keys every layer on its inputs, so a stale or wrong cache costs a miss, never a
wrong build. Verified against the real docker driver (buildx 0.30.1):

| Case | Observed |
|---|---|
| export + import on a *pruned* builder | dependency layer `CACHED`, source layer rebuilt |
| dependency-definition change (the per-PR `.opam` pin) | layer before the change `CACHED`; the dependency layer re-runs |
| Sol's exact argv (`--load`, attestation flags, both cache flags) | `rc=0`, image loaded locally so `docker push` still works |
| cache dir absent (first run) | no `--cache-from`, export only |

Unit tests: `cli/test/test_docker_build.ml` (6 cases) pins all four shapes plus the env
parsing.

## What this does and does not buy

**Does:** reuse of the layers before the dependency install (base image, apt, opam index)
on a runner whose cache survives.

**Does not:** reuse the dependency install itself on a changed `.opam` — and the golden path
deliberately pins the framework to the PR's commit, so that layer is *expected* to re-run:
building the PR's framework is what the smoke test proves. This is why the measured
improvement is bounded by the stable prefix, and the number from CI (not a theory) is
recorded below.
