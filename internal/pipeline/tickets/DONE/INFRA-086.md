---
id: INFRA-086
type: feature
severity: medium
title: `sol local infra up` installs its independent components with bounded concurrency
source: measured golden-path CI timings — ~290s of sequential Helm releases in both languages
---

**Depends on:** None.

**Related:** INFRA-085 (the reverted app-image cache, and the measurements that
pointed here), `.github/workflows/ci.yml` (both golden paths), `cmd_local.ml`,
`Sol_cli_local_infra`.

## The measured problem

`sol local infra up` installed its releases strictly one after another, each one
blocking on its own pods (`helm upgrade --install --wait`). From the CI log
(`main @ 85731f78`, `golden-path-smoke`):

| Release | Time |
|---|---|
| Redpanda | 39s |
| PostgreSQL | 25s |
| Loki | 44s |
| Grafana | 22s |
| Tempo | 53s |
| Prometheus | 38s |
| ingress-nginx | 31s |
| **Total** | **~252s** (+ cluster, repos, port-forwards ≈ 290s) |

The same 290s is paid by both golden paths, in both languages, and by a
developer's first `sol local infra up`. It is the largest shared, avoidable item
left once the application build is understood (INFRA-085 showed the build cache
cannot pay for itself: the scaffold pins the framework to the PR's commit, so the
dependency layer is *supposed* to re-run).

## The dependency model, from the implementation

Not assumed — traced, and the trace is what makes the change safe:

- **The cluster** (k3d + registry) is the only prerequisite of everything.
- **The Helm repositories** are shared mutable state in helm's own config, so all
  five `repo add`s and both `repo update`s now happen *before* any install starts
  (previously ingress-nginx's was interleaved between installs).
- **The releases have no install-time dependency on each other.** Their values
  are literals from the workspace and the platform component profiles; nothing
  reads another release's output. Redpanda's bootstrap job, PostgreSQL's
  StatefulSet and the monitoring charts are independent workloads.
- **Grafana's datasource ConfigMaps** name the Loki/Prometheus/Tempo services, so
  they are applied after the installs return — as they already were.
- **The port-forwards** follow, and are unchanged.

## What landed

`Sol_cli_local_infra.run_bounded` — a narrow thing, not a workflow engine:

- at most **three** installs in flight (a k3d cluster is one node; seven
  concurrent `helm --wait` runs would fight over the same image pulls and CPU,
  and a stuck component would be harder to attribute);
- each install runs in a **forked child** (`Unix._exit`, so the parent's `at_exit`
  handlers do not run once per child) writing its own stdout/stderr to its own
  file, so output stays attributable while three run;
- **the first failure stops new installs from starting**, the ones already running
  are waited for rather than abandoned, failures are reported in plan order, and
  components that never ran are named as not attempted;
- `cmd_local.ml` keeps its install bodies exactly where a reader expects them:
  `helm_install` now records its install instead of running it, and one call to
  `run_local_infra_installs ()` after the last one installs the group. FRIC-006's
  diagnostic (the component's own output, not a bare exit code) is preserved —
  it travels as the failure's message.

## Evidence

- `cli/test/test_local_infra.ml` (3 cases): installs do overlap and never exceed
  the bound; `max_in_flight:1` runs them in plan order; a failing install stops
  the queue (the later component never starts) and the message names both the
  failure and the components not attempted. The overlap is reconstructed from
  start/end events each child writes to a file — with forked children a shared
  counter would not be observable, and the test asserts on what a user could see.
- Local end-to-end: `sol local infra up` in `examples/pluto` completed with all
  components up and every port-forward live, the progress output showing three
  installs in flight and the queue draining. Cluster and port-forwards were torn
  down afterwards; nothing was left running.
- CI: the two golden paths are the real measurement, recorded below once the
  branch has run.

## What was rejected, and why

- **Unbounded concurrency** (all seven at once): one node, and the last 30% of
  the time is image pulls that do not overlap usefully.
- **Threads instead of forks**: the per-component helper exits the process on
  failure; a thread would take the parent and its siblings with it.
- **Dropping the monitoring charts** to save time: that narrows what the golden
  path proves. Higher-value work first, and this change costs no coverage.
