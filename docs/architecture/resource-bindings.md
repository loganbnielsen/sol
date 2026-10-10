# Resource bindings

**Audience:** Contributors changing how a resource's connection reaches a unit or a generated Job —
the migration Job's `POSTGRES_URL`, a workload's Kafka credential and CA, and whatever follows.
**Scope:** How a unit's declared dependencies are resolved to their sources and delivered to the
unit, in every runtime Sol supports. Not a resource framework, not a resource CRUD API, and not a new
configuration surface.

---

## 0. The invariant

> **A unit declares its dependencies and application secrets. The target resolves their sources. The
> runtime delivers exactly the inputs that unit requires.**

Derived rules used throughout:

- **Dependency-scoped delivery.** A unit receives an input only because it declared a dependency that
  requires it, or because it declared the application secret itself. Nothing else is projected.
- **One writer per delivered object.** Exactly one component owns each object a unit reads.
- **Overrides are atomic.** An override replaces the whole binding for a resource; there is no
  field-level merging.
- **Honest failure.** Uncertainty, absence, and partial success are reported as such. An incomplete
  operation never reports success.

The invariant is not Kubernetes-specific: it is a statement about units and their inputs, so it
applies to local development and to runtimes Sol does not implement yet (§4).

## 1. Declarations

Nothing new is introduced. A unit's dependency and secret requirements are declared where they already
are:

```yaml
# sol.yml
resources:
  app_db:
    type: postgres
  events:
    type: kafka

services:
  charge_svc:
    uses: [app_db, events]
```

```toml
# app/payments/charge_svc/sol.toml
[infra.env]
secrets = ["SOL_API_KEY"]   # an application secret the unit reads
```

**The resource name is the identity, and it is used end to end** — in the declaration, in the resolved
binding, in what gets delivered, and in the evidence a deploy records. `uses` is the dependency edge.
There is no separately configured capability namespace, no capability registry, and no new resource DSL
(§8).

## 2. Resolved bindings

A **binding** is an entry in the existing deployment plan — not a new configuration object. For each
resource a target's units depend on, resolution produces one binding that carries:

| Part | Meaning |
|---|---|
| **Resource identity** | The declared name (`app_db`) and type (`postgres`) |
| **Ownership** | Whether Sol provisions the resource, or it is externally managed |
| **Credential source** | Where the authoritative value comes from — the provisioning configuration and its output, or an external store with a remote path per sensitive field |
| **Connection contract** | The complete set of inputs a consumer needs in order to connect |
| **Delivery** | How the value reaches the unit (a delivery detail, §3) |

**The connection contract is complete, or it is not a contract.** Supplying credentials without
endpoints describes nothing connectable. Today the Kafka endpoints are fixed Redpanda addresses in the
renderer, so an externally managed Kafka bound by credentials alone would authenticate to one system
and connect to another. A `kafka` binding therefore carries brokers, the authentication mechanism and
username, the credential, the CA bundle, and the schema-registry endpoint; a `postgres` binding carries
the connection string. Consumers and generated Jobs derive **every** input from the binding, so
endpoints and credentials cannot describe different systems.

**Bindings attach to the resource name and layer like the rest of the configuration.** Environment
defaults, target override, atomic per resource — the same two-level pattern `base_domain`, `registry`
and `cluster_name` already use, merged by the existing layering (`merge_fields` replaces the whole value
per key):

```yaml
prod:
  resources:
    events:                                   # the environment's Kafka
      ownership: external
      store: prod-kafka
      keys:
        KAFKA_SASL_PASSWORD: kafka/workloads/password
        KAFKA_SSL_CA_CERT: kafka/workloads/ca
      connection:
        brokers: kafka.prod.example.com:9093
        schema_registry: https://schema.prod.example.com
  targets:
    aws/eu-west-1:
      resources:
        events:                               # this region's Kafka
          ownership: external
          store: eu-kafka
          keys:
            KAFKA_SASL_PASSWORD: kafka/workloads/password
            KAFKA_SSL_CA_CERT: kafka/workloads/ca
          connection:
            brokers: kafka.eu.example.com:9093
            schema_registry: https://schema.eu.example.com
```

Env-only, target-only, and env+target are all valid — the environment is an optional layer, never a
required one. A resource with no binding is resolved from its ownership by default (§3).

## 3. Ownership, credential source, and delivery are three decisions

They are related but not interchangeable, and conflating them produced earlier confusion:

| Decision | Values | Example |
|---|---|---|
| **Who manages the resource** | Sol provisions it, or it is externally managed | Sol creates the RDS instance |
| **Where its credential comes from** | The provisioning configuration and its output, or an external store | The value lives in Vault |
| **How the unit receives it** | Whatever the runtime delivers | A Kubernetes projection; a local process environment |

A Sol-provisioned database could publish its credential into a store; that would not make the database
externally managed. The three axes combine, and the model must not force one from another.

**Ownership and binding resolve together, and provisioning follows ownership.** If `app_db` is bound as
externally managed, Sol **must not also provision a database for it**. Today `create_rds` is derived
from "does any postgres resource exist", with no notion of the resource being externally managed — that
connection is closed as part of this work (§9), not papered over. The plan refuses a binding whose
ownership conflicts with what the infrastructure would do.

## 4. Runtime delivery

The binding is the contract; the runtime is the mechanism.

- **Kubernetes.** Projections are per consuming namespace, since a unit's reference resolves in its own
  namespace. The renderer chooses the object kind, name, mount, and reference path. **Which object kind
  is an implementation choice, not an architectural rule** — a public CA certificate may travel in a
  Secret because the delivery controller materializes Secrets, without that becoming a claim about
  confidentiality.
- **Local development.** The same resolved bindings, delivered as process environment.
  `sol/secrets.local/` supplies values; the invariant still applies, so a unit receives only the inputs
  it consumes, and a missing required value fails explicitly. Kafka runs plaintext locally, so no
  credential or CA is projected there.
- **Future runtimes.** Because the model states units and inputs rather than Kubernetes objects, another
  backend can deliver the same connection contract by its own mechanism — for example a function runtime
  retrieving from a secret store with its execution role — without pretending Kubernetes objects exist,
  and without any user-managed secret value where workload identity suffices. **None of this is
  implemented now**; the point is that the model does not preclude it, and no backend plugin system is
  built to anticipate it (§8).

## 5. The stable guarantee

> **A unit's declaration, its code, and the connection interface it reads do not change when the
> resource's implementation changes.**

Generated Secret names, reference paths, mount points, and wiring **may** change; the application's
inputs may not. This is the guarantee the application actually needs. Byte-identical manifests are not:
requiring the same destination object under every provider implies a stable writer for that object, so a
provider switch would need an explicit ownership handoff — and the lifecycle rules below deliberately
allow a provider switch to leave the previous object in place while consumers are redirected.

The planner enforces the contract: a provider that cannot satisfy a resource's connection contract is
refused at plan, rather than met with a provider-specific consumer or a generic adapter.

## 6. Lifecycle

**Target configuration owns current resource bindings and secret authority.** From that:

- **Application rollback** restores the application release and resolves its requirements against the
  **current** bindings. It does not restore an earlier credential source. If the release is incompatible
  with the current bindings, the rollback fails explicitly rather than deploying an application wired to
  a source that no longer exists.
- **One writer owns each delivered object.** A projection is never adopted from another writer, and a
  switch of writer does not delete the previous object until consumers have been redirected.
- **Planning checks declared requirements and supported combinations** before anything is applied.
- **Execution establishes the required delivery and readiness evidence** before a workload is considered
  up.
- **Updating a source, delivering its value, and activating it in a running process are three distinct
  outcomes.** A changed value reaches a running process only after a restart; a deploy that wrote a new
  projection has not rotated anything.

Projection reconciliation is idempotent and ownership-safe:

| Situation | Required behaviour |
|---|---|
| Source unavailable | Fail before mutating the projection |
| Source available, projection missing | Create it |
| Source available, projection stale | Update it |
| Projection ownership unknown | Refuse adoption |
| One namespace succeeds, another fails | Report partial failure, naming the namespace |
| Reconciliation interrupted | A subsequent reconcile repeats the operation safely |

Removals stay conservative: obsolete objects are **reported, never silently deleted**, and objects of
uncertain ownership are left in place. Sol removes only what it can prove it owns.

## 7. Acceptance set — the implementation's review checklist

1. **Dependency-scoped delivery** — a unit receives an input only for a dependency it declared or an
   application secret it declared.
2. **Unit isolation** — a unit's inputs contain no other unit's keys; no cross-unit leakage.
3. **Stable interface** — the same unit's declaration, code, and connection inputs are unchanged across
   resource implementations; the consumer declares no provider branch.
4. **Resource identity preserved** — the resource's declared name and type appear in the binding and in
   the recorded evidence, so a delivered value can be traced to the resource it serves.
5. **One writer per delivered object** — no object is written by two components.
6. **Atomic overrides** — an override replaces the whole binding; no field survives from the inherited
   declaration.
7. **No dangling references** — reconciliation does not intentionally remove a projection a workload
   still references, is repeatable after interruption, and never reports an incomplete operation as
   success.
8. **Every value has a named source** — no placeholder, and no fallback default when the source is absent.
9. **No additional authority** — a projection never becomes an independent source of credential
   authority; Kubernetes stores the delivered representation.
10. **Observable resolution** — plan and status show the resolved source for each input and whether it was
    declared at the environment or the target. No internal representation is prescribed.
11. **Resolution is consistent** — availability, requirements, and what the infrastructure actually
    provisions agree for the selected target. A plan must not succeed when provisioning cannot satisfy the
    resolved binding (§9).
12. **Partial failure is reported** — a reconciliation succeeding in one namespace and failing in another
    reports failure and names the namespace; never target-wide success.
13. **Unsupported combinations are refused at plan** — an unknown resource type, a provider that cannot
    satisfy the connection contract, or an unsupported resource count.

## 8. Out of scope

- No separately configured capability namespace, capability registry, runtime registration, or
  independent capability inventory.
- No generic backend plugin system, and no speculative adapters for runtimes or resource types Sol does
  not support.
- No provider-specific branches in consumers.
- No new resource declaration DSL, and no parallel configuration of existing infrastructure resources.
- No independent reconciliation lifecycle: this stays part of target installation and the existing
  deployment prerequisite handling.
- No automatic credential rotation controller, and no sophisticated garbage collection.
- No environment-wide impact-analysis system.
- No more than one provisioned database per target, and no multi-target sharing of a resource.

A new resource type or provider justifies itself through a real consumer and an implemented delivery
path. Sol does not have to provision the resource for that to be true — a Sol-owned consumer contract
plus an implemented delivery mechanism is enough.

**Implementation discipline.** For every new type, configuration field, delivered object, or lifecycle
operation, the change must identify: its authoritative source; whether it introduces a second source of
truth; **which existing module, command, flag, default, or code path it deletes**; who creates, updates,
verifies and removes it; and which acceptance test above establishes the behaviour. A change that adds
machinery without deleting any is reviewed against that absence.

## 9. Implementation notes — current reality, not foundation

These are limitations and mechanisms of today's code. They are recorded so the work is honest about what
it starts from; none of them is a rule of the model.

- **Resource resolution is not yet consistent across providers.** On AWS, `create_rds` follows
  `has_postgres` (`sol_cli_provider_capabilities.ml`), so omitting the resource stops provisioning. On
  GCP the same callback ignores `has_postgres` (`fun ~has_postgres:_ … -> Ok []`) and the cluster root
  declares `google_sql_database_instance.postgres` with **no `count`**, so Cloud SQL is provisioned
  regardless. "Omitting a resource prevents provisioning" is therefore **provider-dependent today**, and
  making resolution consistent is part of this work (§7.11), not an established foundation.
- **The delivery controller materializes Secrets.** ESO produces Kubernetes Secrets, so a projection is a
  Secret under either provider. That keeps a unit's reference stable; the object kind is a delivery
  detail (§4).
- **`@platform` retirement and the migration steps** for existing targets live in the implementation
  issue, not here.
- **The portability claim is a contract claim, not a byte-equality claim** (§5).
