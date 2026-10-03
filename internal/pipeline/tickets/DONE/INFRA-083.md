---
id: INFRA-083
type: decision
severity: low
title: A provider that needs no temporary authority cannot say so — the capability needs an explicit "none"
source: the INFRA-079 decision investigation (item 8), which deliberately did not implement it
---

**Depends on:** None.

**Related:** DEC-048 (the authority rule), `INFRA-079`, `Sol_cli_provider_capabilities.t`,
`Sol_cli_terraform.targets`.

**Reconciled with `DEC-057`/`DEC-051` (2026-09-29):** this ticket gains a second
consumer. `DEC-051`'s `byo` driver owns no cloud Terraform root, and `DEC-057`
requires the installation to be provider-symmetric — both need the capability
record to say "this provider has no authority mechanism / no root", which is
exactly the explicit "none" this ticket asks for. The decision stays open; the
contract raises its priority rather than pre-empting its answer.

## Problem

`capabilities.t` describes a provider's authority mechanism as data — `bootstrap_matchers`,
`bootstrap_scope`, `reconciliation_scope` — and the destroy path always runs the acquisition when
the substrate is present. There is no way to declare *"this provider needs no authority mechanism"*:

- `bootstrap_matchers = []` means "no rule permits anything", not "nothing to acquire": the
  acquisition apply would still run, and its policy would refuse whatever the scope pulled in
  (safe, but a degradation on every destroy);
- the scope cannot express "nothing" either — `Sol_cli_terraform.targets` rejects an empty first
  target, and `Whole_root` is the opposite of what the declaration would mean.

So the current representations offer a provider only two options, both wrong: a refusal-shaped
degradation, or a whole-root acquisition apply.

## Why it is not fixed yet

Both registered providers do need a mechanism, so any change today would be a variant with no
implementation to test it against — and it would add a branch to the bracket
(`with_elevated_access`) that FND-0047 hardened, in the code path that decides whether a destroy
leaves privilege behind. Doing that speculatively is the wrong trade; `INFRA-079` recorded the gap
and stopped.

## The question (answered 2026-10-03, decision below)

Which shape, when a provider that needs none actually arrives (or now, if the review prefers):

1. Make the declaration explicit and total — e.g. `authority = No_authority_required | Mechanism of
   { matchers; scope }` — so the acquisition and the removal are skipped by construction rather than
   by an empty list that means the whole root, with a test that `No_authority_required` skips
   acquisition instead of widening scope.
2. Keep the current data but validate it: fail at capability construction when `bootstrap_matchers`
   is empty or the scope is `Whole_root`, so a provider cannot declare an ambiguous mechanism at
   all.
3. Something smaller, if the review finds it.

## Acceptance criteria

- A provider can be declared with no authority mechanism, and its destroy runs no acquisition apply
  and opens no window (test), or the ambiguous declarations are rejected at construction (test).
- AWS and GCP behaviour is unchanged.
- `with_elevated_access`'s bracket keeps its unconditional-removal property, and any new branch has
  a test in both directions.

## Disposition (2026-10-03) — decision required

Smallest decision: make the authority declaration total (`No_authority_required | Mechanism …`, skipping acquisition by construction), or reject ambiguous declarations (`bootstrap_matchers = []` / `Whole_root`) at capability construction. Consequence: DEC-051's `byo` driver and DEC-057's provider symmetry both need one; the bracket (`with_elevated_access`) gains a tested branch.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.


## Decision (2026-10-03) — make the declaration total

Decided by this pass (internal capability shape; the ticket recommends it and
both DEC-051's `byo` driver and DEC-057's provider symmetry need it): **option 1
— make the authority declaration explicit and total.** A provider declares
`No_authority_required | Mechanism of { matchers; scope }`, so the acquisition and
removal are skipped by construction rather than by an empty list that means the
whole root, with a test that `No_authority_required` skips acquisition instead of
widening scope. AWS and GCP behaviour is unchanged and `with_elevated_access`
keeps its unconditional-removal property. Promoted to
`READY_FOR_ENGINEERING`.

## Completion (2026-10-02) — the declaration is total, and the bracket skips by construction

**Premise verified on `main @ 8b5b0f0f`.** The provider that needs no mechanism cannot say so,
and the destroy runs the acquisition whenever the platform is available:

```console
$ git show 8b5b0f0f:cli/lib/cloud/sol_cli_provider_capabilities.ml | rg -n 'bootstrap_matchers|bootstrap_scope|reconciliation_scope' | tail -3
1067:  ; bootstrap_matchers = []
1068:  ; bootstrap_scope = Sol_cli_terraform.whole_root
1069:  ; reconciliation_scope = (fun _ -> Sol_cli_terraform.whole_root)
$ git show 8b5b0f0f:cli/lib/cloud/sol_cli_cloud_destroy.ml | rg -n 'with_elevated_access|Some Platform_available' | head -6
274:let with_elevated_access ~deps =
301:  | Outputs_available -> Ok (Some Platform_available)
317:  | Some Platform_available ->
318:    let operation, cleanup = with_elevated_access ~deps in
```

So the `byo` declaration reads as *"no rule permits anything"* beside a *whole-root* scope —
a refusal-shaped degradation and an acquisition that would apply the entire root, which are
the two wrong answers the ticket names.

**Implemented.**

- `Sol_cli_provider_capabilities.authority = No_authority_required | Mechanism of { matchers;
  scope; reconciliation_scope }` replaces the three fields. AWS and GCP declare a `Mechanism`
  with exactly the matchers, scope and reconciliation scope they had before; `byo` declares
  `No_authority_required`. There is no way to express "an empty mechanism against the whole
  root" any more.
- The destroy's `deps` carry the mechanism as a variant — `No_authority_required | Mechanism
  of { reconcile_and_enable; remove_elevated_access }` — so a provider with no mechanism has
  no acquisition or removal to call. `with_elevated_access` matches on it:
  `No_authority_required` reports that fact and runs the platform teardown directly, with
  `Cleanup_not_needed` (nothing was opened, so nothing can be left open); `Mechanism` is the
  existing structure, unchanged, including removal running on every exit path.
- The wiring constructs the mechanism's two closures from the declaration's `matchers`/
  `scope`/`reconciliation_scope`, so the matcher list never leaves the `Mechanism` arm.

**Evidence.**

- `cli/test/inline/test_cloud_destroy.ml` — `No_authority_required` runs no acquisition apply,
  no removal, still teardowns the platform, reports why, and returns `Cleanup_not_needed`;
  and a refused teardown under `No_authority_required` is still reported as
  `Platform_destroy_failed` with no cleanup claimed. The other direction is the existing
  `execute: elevated access opened/removed` (acquisition → teardown → removal, cleanup
  recorded) and `execute: protected-operation failure still removes` (the unconditional
  removal the ticket requires to survive).
- `internal/ci/context/test_cloud_lifecycle_offline.sh` — unchanged and green, which is the
  AWS/GCP behaviour-preservation evidence: it asserts the authority acquisition, the platform
  teardown and the authority release run in that order, with the bootstrapped plan asserted.

**Demo/example coverage.** No app-author surface changed — no `sol.toml` field, no scaffold,
no generated manifest, no runtime contract — so no `examples/` or tutorial sample applies. The
runnable behaviour is the destroy lifecycle the offline harness drives.

**Language parity (DEC-022).** No language-parity impact: this is an internal provider
capability shape in the OCaml CLI, with no application-facing convention involved.

**Limitations, recorded.** `byo` is the only provider that declares `No_authority_required`
today, and its `sol cloud destroy` is refused earlier (`Root_not_applicable`: Sol owns no
cloud root for it), so the branch is exercised by the unit tests and by DEC-051's driver model
rather than end to end. `DEC-048`'s vocabulary table was updated to name the total shape.
