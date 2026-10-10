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

- **Dependency-scoped delivery.** A unit receives an input only for a dependency it declared, or
  because it declared the application secret itself. Nothing else is projected.
- **One producer per input.** Each consumer input has exactly one producer. Conflicting producers fail
  at plan — there is no precedence rule and no last-value-wins.
- **One writer per delivered object.** Exactly one component owns each object a unit reads.
- **Atomic binding selection.** A binding override replaces the whole selection for a resource; no
  field of the inherited selection survives.
- **Planning selects the source; execution obtains the value.** A plan names where a value will come
  from; it does not need to contain it.
- **Honest failure.** Uncertainty, absence, and partial success are reported as such. An incomplete
  operation never reports success.

The invariant is not Kubernetes-specific: it is a statement about units and their inputs, so it applies
to local development and to runtimes Sol does not implement yet (§4).

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
resource a target's units depend on, resolution produces one binding carrying:

| Part | Meaning |
|---|---|
| **Resource identity** | The declared name (`app_db`) and type (`postgres`) |
| **Ownership** | Whether Sol provisions the resource, or it is externally managed |
| **Credential source** | Where the authoritative value comes from — the provisioning configuration and its output, or an external store with a remote path per sensitive field |
| **Connection contract** | The complete set of inputs a consumer needs in order to connect, independent of how they are delivered |
| **Delivery** | How the value reaches *this* consumer (§4) — chosen per consumer and runtime, not fixed by the binding |

### 2.1 Planning selects the source; execution obtains the value

A newly provisioned database has no endpoint and no credential when planning starts. That is not an
error. **A plan identifies `app_db`'s provisioning output without containing that output yet**, and an
external secret reference is valid without the planner reading the secret. Execution obtains the value
and establishes the delivery evidence (§6).

Two consequences, and a distinction the implementation must preserve:

- **Serialized plans, release records, GitOps output, and diagnostics contain references and non-secret
  metadata — never confidential values.**
- **A pending source is not an invalid requirement.** A declared resource that does not exist yet is a
  *pending source*; a requirement with no declared resource is *invalid*. They fail — or wait —
  differently, and must not collapse into one error.

### 2.2 The connection contract is complete, or it is not a contract

Supplying credentials without endpoints describes nothing connectable. Today the Kafka endpoints are
fixed Redpanda addresses in the renderer, so an externally managed Kafka bound by credentials alone
would authenticate to one system and connect to another. A `kafka` binding therefore carries the
authentication mode, mechanism, username, brokers, the credential, the CA bundle, and the
schema-registry endpoint — or states the fixed convention it relies on. Fields required for a mode are
required only in that mode: a plaintext connection needs no credential and no CA.

Consumers and generated Jobs derive **every** input from the binding, so endpoints and credentials
cannot describe different systems.

### 2.3 Layering, and what an override replaces

Bindings attach to the resource name and layer like the rest of the configuration — environment
defaults, target override — the same two-level pattern `base_domain`, `registry` and `cluster_name`
already use.

**The resource declaration and its binding selection are different things, and only the selection is
atomic.** `merge_resource` merges resource *attributes* field by field; replacing a resource wholesale
would discard an inherited type or sizing, and merging the selection field by field could combine an
inherited source with a new connection. So:

- **Ownership, credential source, and the connection contract form one atomic value** inside the
  existing resource configuration. An override replaces that value completely; no part of the inherited
  selection survives.
- **Unrelated resource attributes keep the existing field-level merge rules.**

The field name is an implementation choice; the replacement boundary is not.

```yaml
prod:
  resources:
    events:                                   # the environment's Kafka
      binding:
        ownership: external
        store: prod-kafka
        keys:
          KAFKA_SASL_PASSWORD: kafka/workloads/password
          KAFKA_SSL_CA_CERT: kafka/workloads/ca
        connection:
          mode: sasl_ssl
          mechanism: SCRAM-SHA-256
          username: sol-workloads
          brokers: kafka.prod.example.com:9093
          schema_registry: https://schema.prod.example.com
  targets:
    aws/eu-west-1:
      resources:
        events:                               # this region's Kafka
          binding:                            # replaces the selection above, whole
            ownership: external
            store: eu-kafka
            keys:
              KAFKA_SASL_PASSWORD: kafka/workloads/password
              KAFKA_SSL_CA_CERT: kafka/workloads/ca
            connection:
              mode: sasl_ssl
              mechanism: SCRAM-SHA-256
              username: sol-workloads
              brokers: kafka.eu.example.com:9093
              schema_registry: https://schema.eu.example.com
```

Env-only, target-only, and env+target are all valid — the environment is an optional layer, never a
required one. A resource with no binding is resolved from its ownership by default (§3).

### 2.4 Provisioning follows declarations; delivery follows requirements

**Effective resource declarations determine what is provisioned. Consumer requirements determine what
is delivered.** The two must agree for a target (§7.11), but neither derives from the other:

- Migration and contract Jobs are **consumers with internally declared, named dependencies** — they do
  not rely on an ambient default.
- **One producer per input.** If two resources a unit consumes would both supply `POSTGRES_URL`, or the
  unit both declares `POSTGRES_URL` as an application secret and has a database dependency that supplies
  it, the plan **fails**, naming both producers (§7.3).
- **Removing a `uses` edge removes that unit's inputs. It never deletes the resource** — resource
  existence is not a consequence of consumption.

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
externally managed, Sol **must not also provision a database for it**.

**Changing a binding never authorizes destroying or relinquishing the previous database.** Today AWS
uses `count = var.create_rds ? 1 : 0`, so switching an existing resource to `ownership: external` would
take its database out of Terraform's desired configuration — a deletion plan, or a collision with
deletion protection. **v1 refuses an ownership transition for an existing managed resource** until the
operator handles its disposition explicitly through the existing lifecycle. No migration controller is
introduced; this is ordinary lifecycle behaviour, not a compatibility special case.

## 4. Runtime delivery

The binding is the contract; the runtime is the mechanism, and **delivery is chosen per consumer and
runtime** — one resource may serve a Kubernetes consumer and a future function consumer at once.

- **Kubernetes.** Projections are per consuming namespace, since a unit's reference resolves in its own
  namespace. The renderer chooses the object kind, name, mount, and reference path. **Which object kind
  is an implementation choice, not an architectural rule** — a public CA certificate may travel in a
  Secret because the delivery controller materializes Secrets, without that becoming a claim about
  confidentiality.
- **Local development.** The same resolved bindings, delivered as process environment.
  `sol/secrets.local/` supplies values; the invariant still applies, so a unit receives only the inputs
  it consumes, and a missing required value fails explicitly. Local Kafka is plaintext, so no credential
  or CA field is required or projected there.
- **Future runtimes.** Because the model states units and inputs rather than Kubernetes objects, another
  backend can deliver the same connection contract by its own mechanism — for example a function runtime
  retrieving from a secret store with its execution role — without pretending Kubernetes objects exist,
  and without a user-managed secret value where workload identity suffices. **None of this is implemented
  now**; the model does not preclude it, and no backend plugin system is built to anticipate it (§8).

## 5. The stable guarantee

> **A unit's declaration, its code, and its connection interface do not change when the resource's
> implementation changes.**

Stable are the **names, types, and semantics** of the inputs a unit reads. **Values necessarily change**
when an endpoint or credential changes; generated Secret names, reference paths, mount points, and
wiring may change too.

This is the guarantee the application actually needs. Byte-identical manifests are not: requiring the
same destination object under every provider implies a stable writer for that object, so a provider
switch would need an explicit ownership handoff — and the lifecycle rules deliberately allow a provider
switch to leave the previous object in place while consumers are redirected.

The planner enforces the contract: a provider that cannot satisfy a resource's connection contract is
refused at plan, rather than met with a provider-specific consumer or a generic adapter.

## 6. Lifecycle

**Target configuration owns current resource bindings and secret authority.**

**Rollback is: historical application requirements + current target bindings → rollback inputs.** A
rollback restores the application release and resolves *its* named dependencies and application-secret
requirements against the target's **current** bindings; it does not restore an earlier credential source.
That requires the release record to preserve the release's named dependencies and application-secret
requirements, which it does not do today (§9). "Current" means the target's configuration at rollback
time. **Infrastructure ownership changes stay outside application rollback** — rolling back code never
re-provisions or relinquishes a database. Historical source references may remain in the record as
evidence, but they must never silently become the authority again.

From that:

- **One writer owns each delivered object.** A projection is never adopted from another writer, and a
  switch of writer does not delete the previous object until consumers have been redirected.
- **Planning checks declared requirements and supported combinations** before anything is applied.
- **Execution establishes the required delivery and readiness evidence** before a workload is considered
  up.
- **Updating a source, delivering its value, and activating it are three distinct outcomes.** For
  startup-environment delivery, a changed value reaches a running process only after a restart. Runtimes
  that retrieve or reload at runtime have their own activation behaviour, and this rule does not
  generalize to them.

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
3. **One producer per input** — conflicting producers (two PostgreSQL resources both supplying
   `POSTGRES_URL`; an application secret declared for a name a dependency supplies) fail at plan, naming
   both. No precedence rule.
4. **Stable interface** — input names, types, and semantics are unchanged across resource
   implementations; values and generated wiring may change; the consumer declares no provider branch.
5. **Resource identity preserved** — the resource's declared name and type appear in the binding and in
   the recorded evidence.
6. **References, not values** — plans, release records, GitOps output, and diagnostics contain no
   confidential value.
7. **Pending versus invalid** — an undeclared requirement and a not-yet-created source are distinct
   outcomes with distinct diagnostics.
8. **One writer per delivered object**; no object is written by two components.
9. **Atomic binding selection** — an override replaces ownership, source, and connection together; no
   part survives from the inherited selection, while unrelated resource attributes still merge as before.
10. **Ownership transitions are refused** for an existing managed resource until the operator handles its
    disposition; a binding change never produces a silent deletion plan.
11. **Rollback uses current bindings** — historical requirements resolved against current target
    bindings; incompatibility fails explicitly; infrastructure ownership is untouched by rollback.
12. **No dangling references** — reconciliation does not intentionally remove a projection a workload
    still references, is repeatable after interruption, and never reports an incomplete operation as
    success. Removing a `uses` edge removes inputs and never deletes the resource.
13. **Every value has a named source** — no placeholder, and no fallback default when the source is
    absent.
14. **No additional authority** — a projection never becomes an independent source of credential
    authority; Kubernetes stores the delivered representation.
15. **Observable resolution** — plan and status show the resolved source for each input and whether it
    was declared at the environment or the target. No internal representation is prescribed.
16. **Resolution is consistent** — availability, requirements, and what the infrastructure actually
    provisions agree for the selected target (§9).
17. **Partial failure is reported** — a reconciliation succeeding in one namespace and failing in another
    reports failure and names the namespace; never target-wide success.
18. **Unsupported combinations are refused at plan** — an unknown resource type, a provider that cannot
    satisfy the connection contract, or an unsupported resource count.

## 8. Out of scope

- No separately configured capability namespace, capability registry, runtime registration, or
  independent capability inventory.
- No generic backend plugin system, and no speculative adapters for runtimes or resource types Sol does
  not support.
- No provider-specific branches in consumers, and no precedence or last-value-wins rule for inputs.
- No new resource declaration DSL, and no parallel configuration of existing infrastructure resources.
- No independent reconciliation lifecycle: this stays part of target installation and the existing
  deployment prerequisite handling.
- No migration controller for ownership transitions, no automatic credential rotation controller, and no
  sophisticated garbage collection.
- No environment-wide impact-analysis system.
- No more than one provisioned database per target, and no multi-target sharing of a resource.

A new resource type or provider justifies itself through a real consumer and an implemented delivery
path. Sol does not have to provision the resource for that to be true — a Sol-owned consumer contract
plus an implemented delivery mechanism is enough.

**Implementation discipline.** Each PR states **what it replaces**: which existing module, command,
flag, default, or code path it removes or rewrites. The check is at the change level, not per new type.

## 9. Implementation notes — current reality, not foundation

These are limitations and mechanisms of today's code. They are recorded so the work is honest about what
it starts from; none of them is a rule of the model.

- **Resource resolution is not yet consistent across providers.** On AWS, `create_rds` follows
  `has_postgres` (`sol_cli_provider_capabilities.ml`), so omitting the resource stops provisioning. On
  GCP the same callback ignores `has_postgres` (`fun ~has_postgres:_ … -> Ok []`) and the cluster root
  declares `google_sql_database_instance.postgres` with **no `count`**, so Cloud SQL is provisioned
  regardless. "Omitting a resource prevents provisioning" is therefore **provider-dependent today**, and
  making resolution consistent is part of this work (§7.16), not an established foundation.
- **The release record does not preserve named dependencies.** It records rendered configuration,
  secret references, and `consumes_kafka`, but not `uses: [app_db]`, and rollback currently reconstructs
  historical external-secret sources directly. Recording the release's named dependencies and
  application-secret requirements is required for §6's rollback rule.
- **The delivery controller materializes Secrets.** ESO produces Kubernetes Secrets, so a projection is a
  Secret under either provider. The object kind is a delivery detail (§4).
- **v1 delivery support.** Which delivery mode supports which resource authority is an implementation
  limit, not a rule of the model, and is tracked in #1344 (which also carries the `@platform` retirement
  and migration steps for existing targets):

  | Resource authority | Direct deploy | GitOps |
  |---|---|---|
  | Sol-provisioned | Supported; the connection is delivered before the migration Job and workloads | **Refused at plan in v1** — the GitOps flow cannot establish prerequisite readiness for installation-owned projections. Names the options: deploy directly, or bind an external resource through an ESO store. |
  | External | Supported via an explicit target binding | Supported when the ESO-backed binding resolves declaratively; no credential value in Git |

  Kafka follows the same matrix, and the Sol-provisioned Kafka GitOps quadrant is not claimed until a
  confidential credential delivery mechanism is demonstrated. Every supported quadrant needs tests for
  ownership, rendering, ordering, observation, and fail-closed behaviour.
- **The portability claim is a contract claim, not a byte-equality claim** (§5).
