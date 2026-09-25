# Compatibility contract (maturity A)

`production-single-region/v1` claims support only for the exact set below. A
target that selects the profile and resolves outside this set fails preflight
before anything is mutated; there is no "accepted but unverified" outcome
(DEC-026 §4).

All of these inputs are pinned in the repository rather than floating. A
workspace consumes the framework from workspace-owned, immutable opam
dependencies (DEC-025); it does not need `$SOL_HOME` or a Sol source checkout to
build. The workspace-independence proof is the CI job recorded in
`internal/ci/`.

## Framework languages

| Language | Verdict | Evidence or trigger |
|---|---|---|
| OCaml | **qualified** | The first profile's application language. A workload declares `language: ocaml` in `sol.yml`. |
| TypeScript | **staged — not qualified** | DEC-026 §2's triggers: `@sol-fab/worker` needs an `on_ready` equivalent, and the compatibility input below must be able to distinguish language/framework combinations before a TypeScript workload can claim the profile. Until then a profile target containing a TypeScript workload fails preflight. |

A workload declares its language in `sol.yml`:

```yaml
services:
  charge_svc:
    language: ocaml
```

Language is **declared, never inferred** from Dockerfiles, paths or package
metadata — DEC-022 §7 keeps language out of deployment identity, so inferring
it here would be the same wrong abstraction. A profile target fails preflight
if any deployed workload omits its language, or declares one the profile does
not qualify:

- `service "X" does not declare a language; add `language: ocaml` (or `typescript`) to its entry in sol.yml`
- `service "X" declares language typescript, which production-single-region/v1 does not qualify; the first profile is OCaml-only (DEC-026 §2)`

## Pinned inputs

| Input | Supported | Pinned in |
|---|---|---|
| Sol CLI | the built `sol --version` value (`git describe --tags --always --dirty` at build) | `cli/sol/bin/dune` |
| OCaml | `>= 5.4.0` (qualified on 5.4.1) | `dune-project`, `sol-*.opam` |
| Kubernetes (EKS) | 1.36 | `platform/infra/aws/variables.tf` (`kubernetes_version`) |
| Provider module | AWS (`platform/infra/aws/`) — the only qualified provider; GCP is not qualified for this profile | `platform/infra/aws/`, `Sol_cli_provider` |
| cert-manager chart | v1.14.4 | `platform/infra/base/main.tf` |
| ingress-nginx chart | 4.10.1 | `platform/infra/base/main.tf` |
| Argo CD chart | 6.7.3 | `platform/infra/base/main.tf` |
| Redpanda chart | 26.1.11 | `platform/infra/base/main.tf`, `cli/sol/bin/cmd_local.ml` |
| PostgreSQL chart | 18.8.17 | `platform/infra/base/main.tf` |
| Loki chart | 18.12.1 | `platform/infra/base/main.tf` |
| Grafana chart | 13.2.1 | `platform/infra/base/main.tf` |
| Alloy chart | 1.12.1 | `platform/infra/base/main.tf` |
| Tempo chart | 2.3.0 | `platform/infra/base/main.tf` |
| Prometheus chart | 25.20.1 | `platform/infra/base/main.tf` |
| Workspace framework deps | per-workspace immutable pins (DEC-025) | the workspace's `dune-project` and `*.opam` |

`dev` runs the same charts at single-replica scale, so the component versions
above are the ones local development exercises too.

## Scope

One exact supported set is sufficient for maturity A. N/N-1 upgrades, skew
policy, fleet waves and broad provider matrices are out of scope; adding a
second supported set is a later, explicit decision.
