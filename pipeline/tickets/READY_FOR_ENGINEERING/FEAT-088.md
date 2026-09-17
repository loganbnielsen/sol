---
id: FEAT-088
type: feature
severity: high
title: Publish and enforce the maturity-A compatibility contract
source: production platform contract review 2026-09-16
---

**Depends on:** DEC-026.

## Production guarantee

A team can reproduce a production workspace and target using a small, declared
set of compatible Sol CLI, framework, Kubernetes, provider and platform-component
versions. Sol claims support only for combinations it has qualified.

DEC-025 already chose workspace-owned opam dependencies for the OCaml framework,
and FEAT-085 proved workspace independence. RELEASE-005 improves public opam
distribution but need not block maturity A if DEC-025's immutable, workspace-owned
interim satisfies the selected profile. FEAT-087 supplies TypeScript deployed
golden-path coverage if DEC-026 includes TypeScript in the first profile.

## Implementation scope

- Publish the exact initial compatibility matrix selected by DEC-026.
- Pin/lock the profile's substrate and framework inputs in reproducible metadata.
- Validate the selected versions at production-profile preflight and report an
  unsupported combination clearly.
- Prove a clean workspace build without `$SOL_HOME` or a Sol source checkout.
- Keep N/N-1 upgrades, skew policy, fleet waves and broad provider matrices out of
  maturity A; one exact supported set is sufficient.

## Conformance and acceptance criteria

- The matrix identifies the supported CLI, framework language/version,
  Kubernetes version, selected provider module and platform chart versions.
- A clean environment resolves dependencies only from workspace-owned metadata
  and produces the expected artifacts.
- The supported combination provisions and completes a representative
  transaction in HARDEN-002.
- A known unsupported combination fails before production mutation with the
  unsupported dimensions named.
- If TypeScript is included by DEC-026, FEAT-087's deployed golden path is green;
  if deferred, the matrix says so and records the qualification trigger.

**Demo/example coverage:** The production-profile example pins only versions in
the published matrix and builds outside this checkout.

**TypeScript parity:** Resolved explicitly by DEC-026 and recorded in the matrix;
silence is not an acceptable verdict.
