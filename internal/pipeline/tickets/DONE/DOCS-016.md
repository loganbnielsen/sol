---
id: DOCS-016
type: docs-finding
severity: medium
source: pipeline/audits/2026-09-16_docs_audit.md
---

**Depends on:** None.

# Make the first-class OCaml and TypeScript story consistent

README calls both languages first-class, while the tutorial and roadmap still
define Sol as OCaml-only. README and the TS demo also inventory only
`@sol-fab/kafka` and `@sol-fab/obs`, although the runnable service and worker now
consume `@sol-fab/svc` and `@sol-fab/worker` too.

## Acceptance criteria

- README, tutorial, roadmap, and `demo_ts` README agree on the product model.
- All four published `@sol-fab/*` packages and their ownership are documented.
- The mixed-language Pluto example is linked as the current runnable proof.
- Missing TS scaffolding and deployed CI are explicitly linked to FEAT-084 and
  FEAT-087; docs do not claim those incomplete paths already work.

## Completion (2026-09-22)

Closed with one **correction to the ticket's own premise**, because half of it had
aged: AC4 pairs "missing TS scaffolding **and** deployed CI" onto FEAT-084 and
FEAT-087. FEAT-087 is **DONE** — CI deploys `demo_ts` to a real k3d cluster and
asserts pod health, `/healthz` and one live transaction (run 35168274352), and the
jobs run on every PR (`golden-path-smoke-ts`, plus the demo's own install/typecheck
and Dockerfile smoke jobs). So deployed CI is not a gap, and the docs now say it
exists *because it does*. What is still missing is the scaffolding, which was
checked rather than assumed: `sol new` has no `--language` flag and its templates
are OCaml/dune only, so FEAT-084 is the gap the docs now flag.

**Six files changed:**

- `README.md` — four packages rather than two, with ownership stated: `kafka` and
  `obs` each in their own repository, `svc` and `worker` both in
  `loganbnielsen/sol-typescript`. `@sol-fab/svc` and `@sol-fab/worker` are described
  by what they do (the service and worker lifecycle contracts; `svc`'s
  `drainTimeoutMs` matching OCaml's `drain_timeout_s`), and `worker`'s missing
  `on_ready` equivalent is named as one of DEC-026 §2's profile triggers. The
  "being built out to `sol new --language typescript`" sentence no longer reads as
  if that flag exists; it says `sol new` writes OCaml units only and points at
  FEAT-084. The Docs index line lists all four.
- `docs/guides/TUTORIAL.md` — "a production platform for **OCaml** services" →
  both languages, with a note that this walkthrough is OCaml because that is the
  scaffolded path.
- `docs/planning/ROADMAP.md` — the same reframing. TypeScript did not appear in
  this file at all before, so the asymmetry (OCaml deepest, TS broadest on-ramp, TS
  staged behind the profile triggers) is now stated rather than implied by omission.
- `docs/architecture/PRODUCT_ARCHITECTURE.md` — the same opening claim. Not named
  in the ticket, but leaving it would have contradicted the other four files
  AC1 is about.
- `examples/pluto/app/demo_ts/README.md` — four packages, and the "each lives in its
  own repository with its own CI" claim corrected (that is true of `kafka`/`obs`,
  not of `svc`/`worker`). It is the *runnable* path, not the scaffolded one.
- `docs/legal/third-party-licenses.md` — the npm licence inventory covered two of
  the four distributed packages; it now covers all four. `svc` and `worker` are
  Apache-2.0 and carry no dependencies in the lockfile, so they add no runtime tree.

**Verified rather than asserted:** the relative links added
(`../../examples/pluto/app/demo_ts/README.md` from `docs/guides` and `docs/planning`,
`docs/deployment/compatibility.md` from the README) all resolve; and searching for
the old framing (`OCaml software factory`, `platform for OCaml`) now finds none of
these files.

The `@sol-fab/svc`/`worker` ownership comes from FEAT-036's accepted extraction
record — `sol-typescript` is the repository that holds those two — not from
inferring a repository name from the package name.

Documentation-only, so no runtime surface changed; the mixed-language Pluto project
is the referenced example, as the ticket's own coverage note says.

## Demo/example coverage

Documentation-only; the existing mixed Pluto project is the referenced example.
