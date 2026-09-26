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

## Measured on CI (what the numbers actually say)

The first attempt at this **failed** the smoke test in 0.6s, which is why the
implementation is not what the first draft described:

```
ERROR: failed to build: Cache export is not supported for the docker driver.
Switch to a different driver, or turn on the containerd image store, and try again.
```

The verification that had said "works on the docker driver" was run on this
machine, whose docker has the containerd image store enabled; the runner's plain
docker driver cannot export cache. Two changes followed: a container-driver
builder in CI (`docker/setup-buildx-action`, which can export — re-verified
locally on a `docker-container` builder), and a fallback in Sol so a cache can
never be the reason a deploy cannot happen (an export-unsupported failure retries
once without a cache; any other failure is reported unchanged).

Cold run of the branch (cache saved at the end, nothing restored):

| Job | Duration |
|---|---|
| `golden-path-smoke` | 18m15s (baseline 16m26s) |
| `golden-path-smoke-ts` | 12m0s |
| `test` | 7m44s |

Cache entry written: `sol-build-cache-Linux-…`, **1215 MB**, save step 7s. The
cold run therefore cost ~+109s against the baseline (builder setup, a container
BuildKit store, and the cache export), which is the number the warm run has to
beat. The warm measurement follows below.

## Stop rule applied to this unit

The PR wall clock is the *slowest* job, and `golden-path-smoke-ts` sits at ~12m.
Once the OCaml job is at or below that, it is no longer the bottleneck and the
cache has done its job — the remaining cost in both jobs is `sol local infra up`
(~290s of Helm), which is a different change.
