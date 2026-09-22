---
id: INFRA-049
type: refactor
severity: medium
title: Apply DEC-041's `omit` semantics to the deploy selection
source: audit finding FND-0012 — two live observations during AWS Run 8
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0012-omit-does-not-exempt-from-profile-preflight.md`
**Related:** `FND-0023` (the split this ticket is the fix for), `DEC-041` (the decision).

**Depends on:** `DEC-041` — **decided 2026-09-21 and implemented here.**

## The defect as observed

A target that omits a service does not exempt it from the profile preflight. Run
8's target omits the workspace's two TypeScript services; the production-profile
preflight still reports:

```text
- qualified version set is not established [application]: service "order_svc"
  declares language typescript, which production-single-region/v1 does not qualify
- immutable artifact identity is not established [application]: every workload
  must deploy an immutable reference; ...
```

The second error follows from the first: the omitted units are still in scope, and
they have no `--image-ref`. So `sol deploy` of the workspace's OCaml services
without `--scope` cannot pass the preflight. Only `--scope` narrows the view.

`omit` is a real key, and `sol/dev/aws/us-east-1.yml` uses it the same way, which
is what makes the behaviour surprising rather than merely undocumented. `FND-0023`
established the actual split: the config layer *honours* `omit`
(`active_services`), while the deploy selection comes from discovery
(`Sol_cli_manifest.discover_services`), narrowed only by `--scope`.

## Decided semantics (DEC-041)

`omit` means **"not in this target's default set"** — by default it is neither
deployed nor preflighted:

1. **Rule 1 — the deploy selection derives from the omit-filtered config.** The
   preflight reports the services in `plan.services`, so removing a unit from the
   selection removes it from the preflight's view as well. That is the fix: the
   preflight was never the wrong gate, it was being handed the wrong set.
2. **Rule 2 — a unit-level `--scope <domain>/<name>` names it back in**, and the run
   says so. Explicit intent about one unit outranks a target's default.
3. **Rule 3 — a domain-level `--scope <domain>`, and no scope at all, exclude it**,
   and the run says so. Neither names a unit, so an omitted one is never swept back
   in as collateral.

The escape hatch is safe because the profile preflight still runs over whatever
survives, so Rule 2 can only re-admit the deployable-but-non-routine — never the
impossible. The rejected alternative (A2: `omit` as absolute prohibition) and the
separate `forbidden`/`decommissioned` key that would express a real prohibition are
recorded in `DEC-041`.

## Acceptance criteria

1. A target that omits a unit and one that does not behave distinguishably and
   explainably: the omitted unit is absent from both the plan and the preflight.
2. `--scope <domain>/<name>` naming an omitted unit deploys it and says so;
   `--scope <domain>` and a whole-workspace run exclude it and say so.
3. A selection emptied by omission says *that*, rather than reporting "no services
   found in app/", which would send an operator to look in the wrong place.
4. `--image-ref` naming a unit the omission excludes is an error, not a silent drop.
5. Unit tests pin Rules 1–3 without a workspace.

## Out of scope

- The TypeScript parity itself (DEC-026 §2) — this is about what `omit` means, not
  about qualifying the TS demo pair.
- `sol plan`'s discovery-shaped inventory view. DEC-041 Rule 1 is about the deploy
  selection; `sol plan` is read-only and keeps showing what exists.

## Completion (2026-09-22)

- `Sol_cli_config.is_omitted_service` — reads the **raw** declarations, not
  `active_services`. The filtered accessor cannot answer "was this unit omitted?",
  which is exactly the question the deploy asks about a unit it reached by another
  route.
- `Sol_cli_workload_selection.apply_omission` — pure, and keyed on the *request
  kind* (Rule 2 vs Rule 3), returning `selected` / `excluded` / `included`.
- `cmd_deploy.run` applies it immediately after the config load, prints one line per
  included and per excluded unit, errors when an `--image-ref` names an excluded
  unit, and distinguishes an omission-emptied selection from an empty workspace.
  The preflight then runs over the surviving set, so criterion 1 holds by
  construction rather than by a second filter.
- Tests: new `cli/sol/test/test_workload_selection.ml` (6 cases), registered in
  `cli/sol/test/dune`.

**One correction worth recording.** The first version of the partition test asserted
that the three lists are disjoint and partition the selection. It failed, and the
failure was the design's, not the test's: `included` units are *also* in `selected`
(they are deployed), so the correct invariant is that `selected ∪ excluded`
partitions the selection and `included ⊆ selected`. The `.mli` claimed the wrong one
too; both now say the right thing, and the test pins it.

**Demo/example coverage:** not applicable — a CLI selection-semantics change with no
app-author-facing surface. The reproduction from FND-0023 (the by-name plan listing
plus the preflight failure on `order_svc`) is what the new unit tests pin.

`dune build` and `dune fmt` clean; `test_workload_selection` 6/6 and the CLI suite
in `cli/sol/test/` pass.
