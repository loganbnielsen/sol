---
id: CODE_LAYER-012
type: code-layer-finding
severity: medium
source: project/audits/2026-09-06b_code_layer_audit.md
branch: code_layer-012/sun-obs-facade-adoption
worktree: ../sun-code_layer-012-sun-obs-facade-adoption
pr: https://github.com/loganbnielsen/sun/pull/132
---

sun-svc/sun-worker/sun-fn never adopted the Sun_obs facade CODE_LAYER-003 built for them

**Depends on:** None.

## Problem

CODE_LAYER-003 (done, PR #115) added `framework/sun-obs`'s `Sun_obs.t` so
generated app code stops composing `Obs_eio`/`Obs_loki`/`Obs_prometheus`/
`Obs_tempo` by hand. It succeeded for application code, but the three
framework primitives it was meant to sit in front of never actually
adopted it — `framework/sun-obs/lib/sun_obs.mli`'s own doc comment says
so explicitly:

> "These exist for `sun-svc`/`sun-worker`/`sun-fn`'s own `run` functions,
> which each still take a lower-level `Obs_eio.t`/renderer pair directly
> ... rather than a `Sun_obs.t` — not for application code."

Concretely:
- `Sun_svc.Make(H).run` takes `?ot:Obs_eio.t` + `?metrics_renderer`.
- `Sun_worker.Make(W).run` takes the same shape.
- `Sun_fn.Make(F).run` takes a *third*, different shape:
  `?backend:(Obs_eio.backend * (unit -> string))` + `?pushgateway_url` +
  `?job`.

`Sun_obs` has to carry three separate bridge accessors purely to adapt
its own `t` back down to what each primitive still expects
(`Sun_obs.obs_eio`, `Sun_obs.metrics_renderer`,
`Sun_obs.backend_and_renderer`). Scaffolded app entrypoints
(`cli/sun/lib/sun_cli_scaffold_templates.ml`) call `Sun_obs.of_env` and
then thread these three bridges through to the primitive's `run` call —
the composition CODE_LAYER-003 set out to hide is still visible at every
scaffold call site, just one level removed.

No circular dependency blocks fixing this: `framework/sun-obs/lib/dune`
depends only on `eio`/`obs-*`; none of `sun_svc`/`sun_worker`/`sun_fn`
depend on `sun_obs`, and `sun_obs` depends on none of them.

## Goal

`sun-svc`, `sun-worker`, and `sun-fn` all accept one `Sun_obs.t` shape
directly, with no bridge functions needed at the scaffold call site.

## Remediation

- Add `sun_obs` as a library dependency of `framework/sun-svc/lib`,
  `framework/sun-worker/lib`, and `framework/sun-fn/lib`.
- Change `Make(H).run`, `Make(W).run`, and `Make(F).run` to take
  `?ot:Sun_obs.t` (dropping `?metrics_renderer` for svc/worker and
  `?backend`/`?pushgateway_url`/`?job`'s backend half for fn — keep
  `?job` itself, it's not an observability-composition parameter).
  Extract the raw `Obs_eio.t`/renderer/backend each primitive needs
  internally via `Sun_obs.obs_eio`/`Sun_obs.metrics_renderer`/
  `Sun_obs.backend_and_renderer`.
- Delete those three bridge functions from `sun_obs.mli`/`sun_obs.ml`
  once nothing outside `sun_obs` itself calls them.
- Update every scaffold template in
  `cli/sun/lib/sun_cli_scaffold_templates.ml` that wires observability
  into a generated `-svc`/`-worker`/`-fn` entrypoint to pass the one
  `Sun_obs.t` handle straight through instead of unpacking it into two
  or three separate arguments.
- Update `framework/sun-svc/sun-svc.md`, `framework/sun-worker/sun-worker.md`,
  `framework/sun-fn/sun-fn.md`, and `framework/sun-obs/sun-obs.md` to
  describe the unified shape.

## Acceptance criteria

- `Sun_svc.Make(_).run`, `Sun_worker.Make(_).run`, and `Sun_fn.Make(_).run`
  all take the observability handle as `?ot:Sun_obs.t`.
- `Sun_obs.obs_eio`/`Sun_obs.metrics_renderer`/`Sun_obs.backend_and_renderer`
  no longer exist in `sun_obs.mli` (or are private, if some internal use
  remains).
- A fresh `sun new` scaffold's generated `-svc`/`-worker`/`-fn` entrypoints
  pass `~ot:obs` (a single `Sun_obs.t`) to their `run` call, not a
  destructured triple.
- Existing framework/scaffold test suites pass with the updated signature.

## Review — automated checks passed
sun-svc/sun-worker/sun-fn now take ?ot:Sun_obs.t directly; every real caller updated (scaffold templates, pluto/venus examples migrated off pre-Sun_obs hand-composition, local-demo, all framework test suites). Two independent fresh adversarial review rounds: first found a real regression (deriving worker's metrics_renderer from ot auto-starts a port-9090 HTTP listener with no opt-out, hitting two real demo binaries whose docs have the user start a real Prometheus container on that same port); fixed by adding ?metrics_port to the public Worker.Make functor and pinning both demos to metrics_port:0, verified with a live end-to-end run of venus's demo binary against the real Prometheus container (genuine collision test, passed clean). Second round confirmed the fix's correctness (?metrics_port threads through to Impl.run and gating logic verified), audited all 10 Worker.Make call sites in the repo, and live-ran the demo again with no issues. One minor doc gap (missing ?metrics_port in sun-worker.md) fixed. Full unit+kafka+e2e suite green throughout.
