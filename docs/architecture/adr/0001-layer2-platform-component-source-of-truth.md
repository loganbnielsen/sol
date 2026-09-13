# ADR 0001: A canonical source of truth for Layer 2 platform-component config

## Status

Accepted.

## Context

Sol's infrastructure generation splits into three layers with different
portability requirements:

1. **Cluster/cloud provisioning** — `cli/platform/infra/aws/`, `cli/platform/infra/gcp/`,
   each an independent Terraform root module (VPC, EKS/GKE, ECR, RDS,
   Route53, provider IAM). Local dev has no Terraform equivalent — `sol dev
   up` shells `k3d cluster create` directly.
2. **Platform components** — Helm-managed cluster infrastructure: Loki,
   Prometheus, Grafana, Tempo, cert-manager, Redpanda, PostgreSQL, Alloy.
   These are the same applications regardless of which Kubernetes they run
   on.
3. **Application workloads** — sol-generated Kubernetes manifests for
   `-svc`/`-worker`/`-fn`, Services, NetworkPolicies. One shared OCaml model
   (`sol_cli_manifest.ml` → `sol_cli_manifest_yaml.ml` → `sol_cli_deployment_render.ml`)
   renders these identically for `sol up` (local) and `sol deploy` (cloud).

Layers 1 and 3 are sound: Layer 1's providers are genuinely different
infrastructure primitives with no meaningful shared desired state to
extract; Layer 3 already has a single authoritative renderer consumed by
both execution paths.

**Layer 2 is where the architecture breaks down.** Production/cloud
expresses platform-component desired state as Terraform `helm_release`
resources in `cli/platform/infra/base/main.tf`. Local development expresses
the *same* desired state as hand-written `helm install`/`helm upgrade`
calls with inline OCaml values in `cmd_local.ml`. The two are kept in sync
only by a repeated code comment — "Dev mirrors prod exactly" — which
describes an intended invariant but enforces nothing.

This stopped being theoretical when BUG-013 fixed Loki's
`commonConfig.replication_factor` in `cli/platform/infra/base/main.tf` and
nobody thought to check `cmd_local.ml`'s independent Loki config, which
still lacks the fix (BUG-016): a fresh `sol dev up` today can hit the
exact ring-quorum failure BUG-013 already fixed in production. The
follow-up code-layer audit (`pipeline/audits/2026-09-06_code_layer_audit.md`)
found three more instances of the same failure mode (Alloy River config,
Grafana dashboard JSON, missing chart-version pins). The problem isn't
"someone forgot to update Loki twice" — it's that the architecture
*requires* someone to remember to update Loki (and every other component)
twice, forever.

## Decision

Establish `cli/platform/components/<name>/` as the single authoritative home
for platform-component desired state. Each component owns up to three
files:

```
cli/platform/components/loki/
  values-common.json
  values-local.json
  values-durable.json
```

**Format: JSON, not YAML.** The OCaml side has no YAML dependency today
(`cli/sol/lib/dune` pulls `yojson`+`otoml`, no `yaml`); Terraform's
built-in `jsondecode()` needs no provider. JSON is valid input everywhere
YAML is accepted (Helm's `-f`, Terraform's `helm_release.values`), so this
gets both execution paths reading the same files with zero new
dependencies on either side.

**`values-common.json` must stay deliberately sparse.** It holds only
configuration that is genuinely profile-independent — schema versions,
feature flags, log-parsing config, common labels, component behavioral
defaults. It must NOT hold replica counts, persistence topology, storage
classes, object storage config, resource sizing, or ingress behavior —
those are profile-owned. `local` and `durable` are peers, not
prod-with-overrides-undone; if `local` ends up looking like "common plus
a dozen overrides that undo common's assumptions," common absorbed things
it shouldn't have.

**Profiles are named for capability, not environment**: `local` and
`durable`, not `dev`/`prod`. "Durable" describes infrastructure behavior
(object-storage-backed, replicated, retained) and is not permanently
coupled to any one environment — CI can run `local`; staging or a future
integration environment could run `durable` without being production.

**Precedence is fixed and layered by ownership, not just by file order**:

```
values-common.json
      ↓ overridden by
values-<profile>.json   (local | durable)
      ↓ overridden by
infrastructure-bindings  (narrow, mechanically produced from Layer 1 outputs)
```

Each layer may only override what it owns. Precedence tells you who wins
mechanically; the ownership rule tells you who is *allowed* to specify
what — without it, the bindings layer has enough precedence to override
anything, and someone eventually "temporarily" puts `replication_factor`
in the AWS bindings file. Infrastructure bindings carry only
Kubernetes-level contracts Layer 2 already understands (a service account
name, an annotation map, a bucket name, a secret name) — never
provider-specific concepts (no `eks.amazonaws.com/role-arn` string
literal baked into a component's own files; that value is *supplied*
through the binding, the component only declares it needs
`serviceAccount.annotations`).

**Execution layers select and merge; they do not define.** `cmd_local.ml`
becomes: "install Loki using `values-common.json` + `values-local.json`."
`cli/platform/infra/base/main.tf`'s `helm_release` becomes: "install Loki
using `jsondecode(file(...common...))` + `jsondecode(file(...durable...))`
+ this run's infrastructure bindings." Neither owns Loki's configuration
anymore; both own only orchestration.

**Guardrail, applied symmetrically to both execution paths**: CI should
flag new inline Helm configuration growing back in either `cmd_local.ml`
(new `helm_install ~values:[...]` literals for a component that has a
`cli/platform/components/` entry) or `cli/platform/infra/base/main.tf` (new
`set {}` blocks or growing `yamlencode(...)`/`jsonencode(...)` literals
for the same). Removing duplication from one side while letting the other
become the new dumping ground defeats the point.

## Non-Goals

- **No unified infrastructure IR.** Layer 1 stays provider-native and
  separate — AWS, GCP, and k3d are different enough that a common
  representation would be abstraction for its own sake, not a real
  shared-state win.
- **No OCaml-to-HCL generator, no Terraform-generation-from-OCaml, no
  Terraform-managed k3d.** Execution mechanisms (Helm CLI, Terraform
  `helm_release`, kubectl, GitOps emission) are allowed to stay different;
  only desired state needs one owner.
- **No `environment × provider` config matrix** (`values-prod-aws.json`,
  `values-staging-gcp.json`, ...). Deployment profile (`local`/`durable`)
  and infrastructure binding (which cloud, which account) stay independent
  dimensions — a profile file never encodes a provider.
- **No Sol Cloud / managed-platform abstraction** ahead of that becoming
  an active workstream. A `managed` profile is a plausible future addition
  to this same structure, not a reason to build more now.
- **No elaborate lint tooling.** The CI guardrail is a structural grep for
  inline Helm config creeping back into execution-layer files, not an
  OCaml/HCL AST analysis system.

## Consequences

- Fixing a genuinely shared platform-component value (the next BUG-013)
  is one file edit instead of a "remember to also update the other
  system" convention that has already failed once.
- `cmd_local.ml` and `cli/platform/infra/base/main.tf` both get smaller and
  more boring — they orchestrate, they no longer encode.
- Local/durable differences become explicitly inspectable by diffing two
  adjacent files, rather than requiring a reader to hold both a Terraform
  file and an OCaml file in their head at once.
- New cost: every component migrated needs its config split correctly
  into common/local/durable at initial migration time — getting that
  split wrong (over-stuffing common) recreates the coupling under a new
  name, so review should specifically check for it.
- This does not remove the need for judgment: Category A differences
  (replica count, persistence, retention — genuine profile differences)
  become explicit overlay files; Category B differences (port-forwarding
  locally vs. cloud ingress — genuine execution-mechanism differences)
  stay in the execution layers where they belong; only Category C
  (accidental drift, like BUG-013/BUG-016) is what this ADR eliminates.
  Future audits should keep sorting findings into these three buckets
  rather than assuming every local/cloud difference is a bug.

## Related

- BUG-013, BUG-016 — the concrete drift this ADR responds to.
- CODE_LAYER-005 — implementation ticket for this decision.
- CODE_LAYER-006, CODE_LAYER-007 — adjacent duplication (Alloy config,
  Grafana dashboard JSON) in the same class, tracked separately since
  they aren't Helm chart values.
- CODE_LAYER-008 — chart-version pins + immediate value-drift fixes;
  land first if faster, then fold the reconciled values into this
  structure so they stop drifting again.
- `pipeline/audits/2026-09-06_code_layer_audit.md` — the audit that
  surfaced all of the above.
