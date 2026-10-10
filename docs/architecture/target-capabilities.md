# Target capabilities

**Audience:** Contributors adding or changing how a resource's contract reaches a Job or a
workload — the migration Job's `POSTGRES_URL`, the contract Job's Kafka credential and CA, and
whatever follows.
**Scope:** The v1 model for how a target *provides* a capability and how a consumer *requires*
it, in both delivery modes. Not a resource framework, and not a resource CRUD API.

---

## 0. The invariant

> **A unit receives exactly the contract keys of the capabilities it declares plus the
> application secrets it declares; nothing else is projected.**

Object naming, key destinations (Secret vs ConfigMap), and providers are consequences of this
sentence, not independent choices. Three derived rules are used throughout:

- **No key without a named consumer.** A key is projected only because something reads it.
- **The consumer's declaration does not vary by provider** — the acceptance test (§8.1).
- **One identified provider per capability.** Every required capability resolves to exactly one
  identified provider for the selected target. Consumer projections are derived from that
  resolution and never independently determine credential authority.

The invariant is not Kubernetes-specific. It applies to every delivery mechanism Sol owns,
local development included (§10).

## 1. Vocabulary — v1 has two

| Capability | Contract keys | Destination | Consumers today |
|---|---|---|---|
| `database.connection` | `POSTGRES_URL` | Secret | migration Job; units consuming a `postgres` resource |
| `kafka.connection` | `KAFKA_SASL_PASSWORD` | Secret | contract Job; units consuming a `kafka` resource |
| | `KAFKA_SSL_CA_CERT` | Secret | trust material; delivered as a Secret under both providers (§3.4) |

**A resolved capability is a resource contract, not a bundle of environment variables.** The
resolution chain is:

```text
resource declaration  →  provider  →  resolved capability  →  consumer projection
```

A resolved capability carries enough identity to answer: which resource provides it, which provider
owns it, which consumers require it, which material is sensitive, and which lifecycle produces and
refreshes it. It is the contract of an **existing** resource — not an independently configurable
resource object, and not a new inventory (§9).

**One stable consumer contract per capability; a provider is compatible only if it satisfies it.**

| Capability | Consumer contract |
|---|---|
| `database.connection` | one PostgreSQL connection string, `POSTGRES_URL` |
| `kafka.connection` | SASL/SCRAM-SHA-256 authentication with a CA bundle |

An external provider that cannot satisfy that contract — OAuth, mutual TLS client certificates, or a
different connection interface — is **refused at plan**. It is not accommodated with
provider-specific consumer behavior and not generalized behind an adapter (§9). The planner
validates compatibility; it never generates provider-specific consumers.

**Admission rule for a third capability** (all three conditions): a Sol provisioner exists in
`platform/cloud`; at least one Sol-generated consumer exists; the contract keys are stable
enough to name. `cache.connection`, `objectstore.bucket` and `search.connection` fail today.

The rule is a **documented convention, not a runtime check**: a capability is a compiled
artifact — contract keys, a provider, and a projection — so one cannot exist without code in
those three places, and the rule is what that change is reviewed against (§9). Default: not yet.

## 2. Declaration

**Providers are declared on the target**, inside its existing entry in `sol/environments.yml` —
the same block as `cluster_name` and `profile`. No new file, no new section outside it.

```yaml
prod:
  # Environment level: shared by every target of this environment.
  secrets:
    payments/charge_svc:
      STRIPE_API_KEY:
        authority: external
        store: prod-vault
        key: secret/production/payments/stripe
  capabilities:
    kafka.connection:
      provider: external
      store: prod-kafka
      keys:
        KAFKA_SASL_PASSWORD: kafka/workloads/password
        KAFKA_SSL_CA_CERT: kafka/workloads/ca

  targets:
    aws/us-east-1:
      cluster_name: pluto-prod-use1
      # inherits the environment's secrets and capabilities unchanged
    aws/eu-west-1:
      cluster_name: pluto-prod-euw1
      # one reference differs, so override exactly that one
      secrets:
        payments/charge_svc:
          STRIPE_API_KEY:
            authority: external
            store: eu-vault
            key: secret/production/payments/stripe
      capabilities:
        # Present only to bind an external database. Absent = the target provides the
        # database its effective resource graph consumes.
        database.connection:
          provider: external
          store: prod-db
          keys:
            POSTGRES_URL: pluto/app-db/url
```

**`secrets:` and `capabilities:` are valid at both levels; the target overrides the environment.**
Env-only, target-only and env+target are all valid — the environment is an *optional layer above*
the target, never a required one. This is the same two-level pattern `base_domain`, `registry` and
`cluster_name` already use, and it exists for the common case where several targets of one
environment share a reference: one vault path, three regions.

**Merge boundaries are exact and closed.**

- Secrets merge by **`unit/key`**.
- Capabilities merge by **capability name**.
- A secret override replaces its **complete authority declaration** — the whole
  `Sol_managed | External { store; key }` value.
- A capability override replaces its **complete provider declaration**, including every entry in
  its `keys:` mappings.
- **No field-level or recursive merging occurs inside either declaration.** There is no way for a
  `store` to survive from the inherited declaration while the `key` changes.

`secrets:` already behaves this way: `merge_fields` upserts each key with the incoming value.
`capabilities:` will follow the same rule. **No new configuration hierarchy and no generic merge
engine** — the existing layering is the mechanism.

**`secrets:` inheritance already works; `capabilities:` is new work.** `secrets` decodes as a
target field (`target_key_of_string`), and unlike `cluster_name`/`registry` it is not in
`target_only_keys`, so an environment-level declaration is accepted. The loader applies the
environment layer and then the target layer (`apply … env_layer`, then `apply … target_layer`),
merging through `merge_target` → `merge_secret_authorities` → `merge_fields`. Env-only,
target-only and env+target already resolve today.

**The existing provisioner setting is the declaration; the capability block is external-only.**
`create_rds` is not a target field — the CLI derives it, and the derivation is already
**target-scoped, not workspace-scoped**. `Sol_cli_config.resources cfg` filters omitted resources,
`Sol_cli_terraform_vars.of_config` is called from the environment stage with the resolved per-target
config, and only then is `has_postgres = List.exists (r.typ = Some "postgres")` computed.
`root_declared_vars ~has_postgres` sets `create_rds = has_postgres` **regardless of profile**
(`sol_cli_provider_capabilities.ml`); the profile adds only multi-AZ and deletion protection
(`production_postgres = has_postgres && production`). So a target whose *effective* resource graph
contains a postgres resource provides `database.connection` with no declaration at all.

**`provider: sol` is not accepted.** The effective resource graph is the only declaration of a
Sol-provisioned capability; a second statement of it could disagree with the graph, so the block
exists solely to override to `external`, and writing `provider: sol` is refused rather than
tolerated as a redundant form.

**External references are per contract key.** The existing authority type is already per key —
`External { store; key }`, held as `secret_authorities : unit → key → authority` — so a
capability whose contract has two keys names two remote paths. That is also the shape ESO renders:
one `ExternalSecret.data` entry per key, each with its own `remoteRef`. A single `key:` for a
multi-key capability would be unrenderable.

**Consumers require capabilities without naming a provider:**

- **Jobs are implicit.** Sol owns the migration Job's and contract Job's contracts.
- **Units use the existing graph.** `sol.yml` `resources:` declares the type (`postgres` →
  `database.connection`, `kafka` → `kafka.connection`) and `services[].uses` is the edge. No new
  DSL.

**The meeting point is plan time.** A required capability with no provider **fails at plan**, not
deploy — §3.3 states this concretely for the database. Where `provider = sol` but no provisioner
exists for that capability (Kafka until a generated credential lands), the plan fails naming the
missing provisioner and the external alternative.

## 3. Fulfillment

- **`sol`** — Sol's infrastructure provisioning *configuration* supplies the authoritative
  credential inputs. Terraform **outputs** (`postgres_url` in
  `platform/cloud/{aws,gcp}/cluster/outputs.tf`) expose the connection information *derived from*
  those inputs and the provisioned infrastructure. Target install/reconcile consumes that
  information to produce the Kubernetes projections. The output is the reporting of the
  authoritative configuration, not a separate authority.
- **`external`** — the target names an external secret provider's store and a remote path per
  contract key; Sol renders a namespaced `ExternalSecret` into the app bundle's prerequisites (the
  existing external-secret path). **The external provider — Vault, Secrets Manager, … — is the
  authority; ESO is the delivery controller that materializes it; Kubernetes stores the delivered
  representation.** Keeping authority and delivery distinct is the point of this section.
- The consumer is identical either way (§8.1).

### 3.1 What reconciliation can and cannot do

- **Out-of-band password changes are not discovered.** If an operator changes the database password
  outside Sol, no configuration changed and reconciliation has nothing to re-derive from.
  Re-reading a Terraform output does not recover a credential that was changed in the database.
- **Reconciliation cannot invent an unknown credential.** It derives the intended value from the
  declared authoritative source; when that source no longer reflects reality, the projection is
  stale and Sol cannot tell.
- **Updating a Kubernetes Secret does not refresh a running process.** Environment variables are
  read at process start, so a changed projection reaches a workload only after a restart. This is
  the same restart requirement as the Kafka credential.
- **v1 does not add rotation.** No automatic rotation and no new credential-synchronization
  controller (§9); rotation is a deliberate operator action followed by a restart.

### 3.2 Projection objects are per capability *per namespace*

Kubernetes Secrets are namespace-scoped and a unit's `secretKeyRef` resolves in its own
namespace, so a target with consumers in three namespaces has **three projection objects per
capability** (for example three `sol-database-connection` Secrets), all produced from the same
source. It is *not* one object per target. Stating it here because "one per capability" is the
natural misreading and it breaks cross-namespace consumption.

**Reconciliation updates every namespace it is responsible for, and reports partial failure
accurately.** If a projection succeeds in one namespace and fails in another, the operation
**reports failure and names the affected namespace**; it must not report target-wide success
(§8.12).

### 3.3 One effective database per target

The provisioner creates exactly one database per target cluster — `aws_db_instance.postgres` with
`count = create_rds ? 1 : 0` and `db_name = "app"` — and `has_postgres` is a single boolean that
carries **no resource identity**. **v1 therefore supports at most one `postgres` resource in a
target's *effective resource graph***: the count after `omit` is applied, not the count a target's
units happen to consume.

A workspace may declare several `postgres` resources, but **each target must omit the ones it does
not provision**, because the provisioning path cannot select between them. A target whose effective
graph contains two `postgres` resources is refused at plan, naming both — regardless of which ones
its units consume. Multi-database would require the capability to carry an env-var mapping and the
provisioner to preserve resource identity; both are explicitly future work (§9).

**Provisioning depends on effective resources; projection depends on consumers.** The effective
resource graph decides what exists; `uses` decides who receives access. Capability resolution must
not let an application dependency edge select which infrastructure resource is provisioned, so v1
does not select between multiple effective PostgreSQL resources based on consumption.

### 3.4 The Kafka CA is a Secret under both providers

ESO materializes Kubernetes **Secrets**, not ConfigMaps. Delivering `KAFKA_SSL_CA_CERT` through a
ConfigMap for a Sol-provisioned Kafka while an external Kafka delivers it through an ESO-managed
Secret would change the consumer's volume reference by provider, violating §8.1. v1 therefore
delivers the CA as a **Secret under both providers**: the Sol provisioner writes a Sol-managed
Secret, and the external path writes an ESO-managed Secret.

A public CA certificate does not become confidential because Kubernetes stores it in a Secret, and
nothing is gained by putting it in a ConfigMap. The requirements are provenance, protection from
unauthorized modification, and delivery identical under both providers. ConfigMap delivery is
**not v1**: it would need a second writer and its own lifecycle to convert ESO-provided material
(§9).

### 3.5 What plan does at the database boundary

**Two `postgres` resources in a target's effective graph.** The refusal is per target and counts
the **effective graph, not consumption**: a target that keeps both `app_db` and `analytics_db`
non-omitted is refused at plan, naming both, even when its units consume only one — because the
provisioner makes one database and `has_postgres` carries no identity to select with. The supported
multi-resource shape is `omit`: target A omits `analytics_db`, target B omits `app_db`, and each
then provisions exactly the one it keeps. `has_postgres` answers only *whether a provisioner is
configured for this target*, and must not be reused as the refusal, or a target is refused for
another target's state.

**Omitting a resource removes it from the effective graph.** `omit` is settable per layer and
`Sol_cli_config.resources` filters omitted entries before `has_postgres` is computed, so a target
that omits its postgres resource neither provisions a database nor provides `database.connection`.
Resource-graph validation and infrastructure provisioning must read the **same** effective graph
(§8.11).

**A non-production profile.** `create_rds = has_postgres` is profile-independent, so a dev target
whose effective graph contains a `postgres` resource still provisions one. The profile only decides
durability (`production_postgres = has_postgres && production` → multi-AZ, deletion protection).
There is no "dev binds externally instead" behaviour, and none is implied.

**A consumer requires `database.connection` and the target cannot provide it** — no `postgres`
resource in the effective graph, and no `capabilities.database.connection` at either level. **Plan
fails** with a message naming the two ways to satisfy it: declare a `postgres` resource (which makes
the target's provisioner bring one up), or bind the capability to an external authority at the
environment or target level. It never proceeds to deploy and fails later on a missing key.

**The plan is a gate, not a hint.** `sol deploy` builds the plan first (`build_plan` in
`cmd_deploy.ml`) and returns its error before the environment stage, destination resolution, or any
apply — so a refused plan cannot be applied past, and every refusal above is enforced on the apply
path, not only under `sol plan`.

## 4. Delivery quadrants

| | direct apply | GitOps (`--emit-to`) |
|---|---|---|
| **external** | the bundle carries the `ExternalSecret`; Sol waits for `Ready`/`SecretSynced`, plus the soft generation check | the same object is emitted; Argo and ESO reconcile it; Argo owns the wait |
| **sol** | the projection exists from target install; app deploy never writes it | **refused at plan in v1** (§4.1) |

Mode differences are only *who waits*. The emitted bytes are the contract.

### 4.1 GitOps with a Sol-provisioned capability is refused in v1

GitOps with a Sol-provisioned capability is refused in v1 because **the GitOps deployment path
cannot establish prerequisite readiness for installation-owned credential projections before
workload reconciliation**.

Argo does not need to own these projections — an installation-owned Kubernetes Secret is a
legitimate external prerequisite of an Argo-managed workload. The gap is that Sol currently has no
mechanism in the GitOps flow to verify such a prerequisite's existence and readiness, nor a defined
way to invoke installation reconciliation from that flow. Direct deployment can establish
readiness before applying workloads; GitOps has no equivalent integration.

So the plan refuses the quadrant, with a clear explanation and the supported alternatives: deploy
directly, or bind the capability to an external authority delivered through ESO — which remains
fully supported, because the bundle itself carries the `ExternalSecret`.

**1344d does not open this quadrant.** No reconciliation controller, Argo integration, or new
installation lifecycle is added for it. A future version may add an explicit mechanism for
verifying and reconciling installation-owned projections from the GitOps flow.

## 5. What this replaces

- `@platform/POSTGRES_URL`, `@platform/KAFKA_SASL_PASSWORD`, `@platform/KAFKA_SSL_CA_CERT` →
  capability projections. `@platform` parsing, addressing, and commands are **actually removed**,
  and an error names the replacement.
- `default_secrets` → **deleted, not emptied, and not relocated.** It had two lives: the
  `secret_doc` base and `required_secret_keys`. Both go; the Kafka keys follow the capability
  requirement, so a unit that consumes no `kafka` resource stops requiring them.
- `runtime_secret_name = "sol-secrets"` → one projection object per capability per namespace
  (§3.2), so each object has one owner and none becomes a new shared bucket.
- `SOL_API_KEY` is already a declared unit secret, not a workload default.

## 6. Lifecycle

- **Owner** — the target. Projections die with the target; applications never own them; an
  application rollback does not touch them.
- **Rotation, `sol`** — refreshed by target reconcile. v1 requires re-running install/reconcile;
  automatic rotation is out of scope.
- **Rotation, `external`** — ESO semantics: source rotation needs a workload restart; a spec change
  is waited on softly.
- **Rollback** — re-renders the app bundle only; `external` projections re-render with it, `sol`
  projections are untouched.
- **Drift** — reconciled by the projection's writer: the installation for `sol`, ESO for `external`.
  Nothing application-side repairs it.
- **Partial failure** — reconciliation reports per namespace and never claims target-wide success
  when one namespace failed (§8.12).
- **Inheritance blast radius** — an environment-level change reaches **every inheriting target**; a
  target-level change reaches only that target. Rotation follows the same rule: if `prod` declares
  `store: prod-vault` and `eu-west-1` overrides to `eu-vault`, rotating at `prod-vault` affects
  every inheriting target *except* `eu-west-1`. v1 relies on per-target `--dry-run` to preview a
  change; an env-wide change report is deliberately not built (§9).

### 6.1 Projection lifecycle

| Situation | Required behaviour |
|---|---|
| Source unavailable | Fail before mutating the projection |
| Source available, projection missing | Create it |
| Source available, projection stale | Update it |
| Projection ownership unknown | Refuse adoption |
| Namespace A succeeds, B fails | Report partial failure, naming the namespace |
| Capability removed | Stop projecting to new consumers; preserve objects still referenced until cleanup is provably safe |
| Reconciliation interrupted | A subsequent reconcile repeats the operation safely |
| Credential changed | Report that running workloads may still use the previous value |

This requires **idempotence, safe ordering, and honest reporting** — not atomic cross-namespace
updates, and not a new reconciliation framework. Switching providers must not delete the previous
projection until consumers have been safely redirected (§7).

## 7. Moves and removals — report, never delete

Two cases share one rule.

- **`@platform` retirement.** The old `sol-secrets` object is not auto-deleted. Sol does not
  silently remove a populated object; the deploy reports it as unreferenced and the operator removes
  it.
- **Authority migration** (§8.8). When a key moves between `sol` and `external` — or a capability
  moves between providers — Sol **reports the object the move orphans** (the previous writer's
  Secret or `ExternalSecret`) and leaves it in place.

Cleanup and orphan reporting respect **target, namespace, and release ownership boundaries**: a
projection observed in a namespace is only removed when Sol can prove it owns it there.

This keeps every removal in the same discipline as resource ownership: Sol removes only what it can
prove it owns, and a populated object that may still hold a live credential is not proof.

**Cleanup stays conservative in 1344d.** No sophisticated garbage collection: obsolete credential
objects are reported, and objects of uncertain ownership are left in place.

## 8. Acceptance set — the implementation's review checklist

1. **Provider independence** — the consumer's rendered **pod-template fragments** are byte-identical
   under both providers (not the complete manifests: provider-specific prerequisite resources
   legitimately differ), and the template contains no provider branch.
2. **No key without a consumer** — every projected key has a named consumer contract.
3. **Unit scope preserved** — a unit's Secret holds only its declared keys plus its capabilities'
   contract keys; no cross-unit leakage.
4. **No dangling references** — reconciliation must not **intentionally** remove a projection while
   an existing workload still references it. On failure or interruption, previously referenced
   projections remain available wherever possible, and the next reconciliation converges safely to
   the intended state; an incomplete operation must not report success. **Safe ordering and
   repeatable reconciliation are required; atomic multi-resource transactions are not claimed**, and
   this criterion must not be read as a promise of them.
5. **Every new object has a named source** — each projected value has a producer (install output or
   ESO store), never a placeholder, and never a fallback default when the source is absent.
6. **No additional authority** — a projection must not become an independent source of credential
   authority. Reconciliation derives its intended value from the declared authoritative source;
   Kubernetes stores the delivered representation. Persistence of the Secret is not itself a
   violation.
7. **All four quadrants are answered** — {direct, GitOps} × {sol, external}, per §4, with §4.1 as
   the v1 refusal.
8. **Authority migration is reported** — a move between providers reports the object it orphans
   (§7); no silent change and no silent deletion.
9. **Observable provenance** — `sol plan` and `sol secret status` show the resolved authority for
   each key and whether it was declared at the environment or the target. Do **not** track or
   display every intermediate inheritance decision, and do not prescribe an internal
   representation: use the smallest mechanism that produces the diagnostic without threading
   provenance through deployment, release, or rollback.
10. **Inheritance behaves** — tests cover env-only, target-only, env+target override, an atomic
    override (no `store` carried over from the inherited declaration), a missing authority, and
    cross-target isolation.
11. **Resource-graph consistency** — capability availability, consumer requirements, and
    infrastructure provisioning resolve against a **consistent effective resource graph for the
    selected target**. A plan must not succeed when the infrastructure it provisions cannot satisfy
    the resolved capability contract. Tests cover both successful selection and refusal, including
    omitted resources and multiple `postgres` declarations.
12. **Partial projection failure is reported** — a reconciliation that succeeds in one namespace and
    fails in another reports failure and names the affected namespace; it never claims target-wide
    success.
13. **CA destination consistency** — `KAFKA_SSL_CA_CERT` is delivered as a Secret under both
    providers, and the consumer's volume reference does not change with the provider (§3.4).
14. **Capability identity is resolved, not configured** — a required capability resolves to exactly
    one identified provider for the selected target; a provider that cannot satisfy the capability's
    consumer contract (§1) is refused at plan rather than met with a provider-specific consumer.

## 9. Out of scope

Multi-target sharing of a capability; resource CRUD independent of the target lifecycle; capability
types beyond database and Kafka; a new `resources:` DSL; automatic rotation; cross-cloud
portability; multi-database-per-target; environment-wide change reports (per-target `--dry-run`
covers previewing a change); and — for v1 — GitOps with a Sol-provisioned capability.

Implementation non-goals, stated so a diff can be checked against them:

- No generic capability registry and no runtime capability registration.
- No independent capability inventory and no separate capability reconciliation lifecycle. Capability
  reconciliation stays part of target installation and the existing deployment prerequisite
  handling.
- No new resource declaration DSL and no parallel configuration of existing infrastructure
  resources.
- No redundant `provider: sol` configuration — the effective resource graph is the declaration.
- No ConfigMap delivery for the Kafka CA, and no second writer or lifecycle to produce one.
- No provider-specific branches in consumers and no generic adapters for unsupported protocols.
- No independently configurable capability objects.
- No speculative adapters for future capability types.
- No automatic credential rotation controller.
- No environment-wide impact-analysis system.

Capabilities remain a small, compiled contract for the concrete PostgreSQL and Kafka requirements
Sol supports today. A third capability justifies itself through an actual provisioner, a consumer,
and a stable contract — not hypothetical extensibility.

**Implementation discipline.** For every new type, configuration field, Kubernetes object, or
lifecycle operation, 1344d must identify: its authoritative source; whether it introduces another
separately maintained source of truth; **which existing module, command, flag, default, or code path
it deletes**; who creates, updates, verifies and removes it; and which acceptance test in §8
establishes the required behaviour. A change that adds machinery without deleting any is reviewed
against that absence.

## 10. Local development — the same invariant

The §0 invariant applies locally as it does in Kubernetes. The **delivery mechanism** differs —
`sol/secrets.local/` rather than Secrets and ESO — but the requirement to project only consumed
credentials does not.

`cli/lib/local/sol_cli_local_run.ml` currently injects `POSTGRES_URL` and `SOL_API_KEY` into every
local workload regardless of whether the unit consumes them. That is a defect against §0, not a
deliberate exception, and 1344d corrects it:

- **`POSTGRES_URL`** is derived from the existing resource dependency graph: units that consume a
  postgres resource receive the connection; units that do not, do not. A missing required local
  credential fails explicitly, as it does today.
- **`SOL_API_KEY`** is injected only for units that require the local plaintext peer-auth fallback.
  **Which units those are is not yet established, and must be traced before this part is
  implemented.** The authentication implementation decides it, not the existence of a service
  dependency: the trace covers which local callers need the key, whether local callees independently
  require it (a unit serving an authenticated route may need it too), whether the declared `calls`
  graph identifies the complete set, and how `SOL_ALLOW_PLAINTEXT_PEER_AUTH` changes the requirement.
  `calls` is a candidate signal, **not a proven one**.
- If the existing declarations identify the consumers, use them. **If they do not, report the precise
  limitation and keep the authentication change separate from credential-capability delivery** — do
  not add another declaration or an authentication abstraction merely to remove a hardcoded default.
- The explicit development-only plaintext opt-in (`SOL_ALLOW_PLAINTEXT_PEER_AUTH`) is preserved.
- Kafka keys remain outside the local set: local Kafka runs plaintext, so no SASL credential or CA
  is projected locally.

**Acceptance:** a Kafka-only workload receives neither `POSTGRES_URL` nor an unrelated API key,
while workloads with demonstrated credential requirements receive both correctly.

The environment/target inheritance model (§2) does not apply locally: `sol/secrets.local/` is per
workspace and has no environment layer, so there is nothing to inherit from.
