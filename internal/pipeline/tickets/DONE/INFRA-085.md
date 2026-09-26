---
id: INFRA-085
type: feature
severity: medium
title: Application image builds can reuse BuildKit cache (and the CI golden path persists it)
source: measured golden-path CI timings — the first scaffolded OCaml app image costs 297s cold
---

**Depends on:** None.

**Related:** `.github/workflows/ci.yml` (golden-path jobs), `Sol_cli_docker`,
`platform/local/scripts/*` (no), `internal/planning/WORK_SUMMARY.md`.

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

## Result: measured, and **not landed**

Warm run (cache restored; a fifth commit pushed to get a fresh run id, which is
what a normal PR flow does):

| Run | `golden-path-smoke` | `golden-path-smoke-ts` | `test` |
|---|---|---|---|
| baseline (`main`, before this work) | 16m26s | 11m10s | — |
| cold (cache saved, nothing restored) | 18m15s | 12m0s | 7m44s |
| warm (1215MB cache restored) | **17m47s** | 11m48s | 9m49s |

**28 seconds of "improvement" from cold to warm, against a baseline it is 81s
slower than.** The cache does not pay for itself on these runners.

That is consistent with the layer analysis, and the analysis is why: the
scaffolded `.opam` pins the framework to the PR's commit, so the dependency
install (the 297s) is *supposed* to re-run — building the PR's framework is what
the smoke proves. Only the stable prefix (base image, apt, opam index) is
cacheable, and reaching it costs a container-driver builder plus `--load`, which
is the same order as the pull it replaces. The measured failure mode also cost a
cycle: this machine's docker has the containerd image store enabled, so "verified
against the real docker driver" was verified against a *different* driver
configuration than the runner's, which is why the first CI run failed in 0.6s.

So the change was reverted rather than landed: no `SOL_BUILD_CACHE_DIR`, no
buildx step, no 1.2GB cache entry per run, nothing dead in `Sol_cli_docker`. What
this ticket keeps is the measurement, the driver lesson, and the layer model —
the next person who reaches for an image-build cache here starts from numbers
instead of hope.

## What the numbers say the remaining cost is

Both golden paths are now dominated by the same two things, neither of which is
the application image build:

| Phase | OCaml job | TS job |
|---|---|---|
| Setup (toolchain, opam pins, framework deps, `sol build`, k3d/kubectl/helm) | ~350s | ~330s |
| `sol local infra up` (seven Helm releases, sequential, `--wait`) | ~290s | ~290s |
| Application work | ~330s (mostly the per-PR dependency build, inherent) | ~40s |

The platform bring-up is the largest *shared*, *avoidable* item: seven
independent releases (Redpanda, PostgreSQL, Loki, Grafana, Tempo, Prometheus,
ingress-nginx) installed one after another, each blocking on its own pods. Their
install-time dependencies are only on the cluster and on the Helm repositories;
Grafana's datasource ConfigMaps come after them, and the port-forwards after
that. That is the next unit's subject, not this one's.
