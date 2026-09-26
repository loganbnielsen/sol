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

## Decision Required

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
