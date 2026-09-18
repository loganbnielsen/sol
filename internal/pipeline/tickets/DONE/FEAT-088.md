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

## Unresolved input: how language qualification is represented

DEC-026 §2 says a profile-selecting target containing a TypeScript workload fails
preflight. FEAT-089 found that nothing in the plan, manifest, `sol.toml` or
release identity says what language a workload is implemented in. DEC-022 §7
deliberately keeps language out of deployment identity, and FEAT-089 must not
inspect language-specific build metadata. FEAT-089 therefore implements no
language check: its `qualified_versions` guarantee stays unmet for every target
until this ticket establishes it.

This ticket must define an explicit compatibility input if production
qualification has to distinguish language/framework combinations. Inferring the
language from Dockerfiles, paths, package metadata or other build details is
the wrong abstraction and is not an acceptable resolution.

**Demo/example coverage:** The production-profile example pins only versions in
the published matrix and builds outside this checkout.

**TypeScript parity:** Resolved explicitly by DEC-026 and recorded in the matrix;
silence is not an acceptable verdict.

## Outcome (2026-09-17)

The profile's qualified version set is now a real preflight check backed by an
explicit, language-neutral input, and the supported set is published.

- **The explicit compatibility input is the declared language.** Each `sol.yml`
  service entry may declare `language: ocaml` or `language: typescript`
  (`Sol_cli_compat`). Nothing infers it from Dockerfiles, paths or package
  metadata — DEC-022 §7 keeps language out of deployment identity, so a guess
  would be the same wrong abstraction the ticket rejects. An unknown value fails
  `sol.yml` parsing with the supported values.
- **Preflight enforces it.** `Qualified_versions` is established only when every
  deployed workload declares a language and the profile qualifies it. An
  undeclared language, or `typescript`, is reported as an application-side
  finding naming the fix; DEC-026 §2's TypeScript rejection now has the signal
  FEAT-089 was missing.
- **The matrix is published.** `docs/deployment/compatibility.md` records the
  supported OCaml and staged-TypeScript verdicts (with the qualification
  trigger), and the pinned CLI, OCaml, Kubernetes, AWS provider-module and
  platform-chart versions, each with its pin location. The profile contract and
  the pluto README link to it.
- **Reproducible metadata already exists** and is referenced rather than
  duplicated: DEC-025 workspace-owned immutable opam pins, the chart pins in
  `cli/platform/infra/base/main.tf`, and the workspace-independence CI proof.
- One exact supported set is deliberate; N/N-1 upgrades and broad provider
  matrices stay out of maturity A.

Premise check: `Sol_cli_profile_preflight.establish` reported
`Qualified_versions` as `not_yet_established` for every target, and no
`language` input existed in `sol.yml`/`Sol_cli_config`, so the finding was
actionable.

**Demo/example coverage:** `examples/pluto/sol.yml` declares `language: ocaml`
for its OCaml services and `language: typescript` for the `app/demo_ts` pair, so
the pilot target demonstrates the preflight reporting TypeScript as not yet
qualified. `examples/pluto/README.md` explains the declaration and links the
matrix.

**TypeScript parity:** TypeScript is explicitly recorded as staged (not
qualified) for the first profile, with DEC-026 §2's triggers, rather than
silently omitted.
