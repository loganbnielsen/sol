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
sentence, not independent choices. Two derived rules are used throughout:

- **No key without a named consumer.** A key is projected only because something reads it.
- **The consumer's declaration does not vary by provider** — the acceptance test (§8.1).

## 1. Vocabulary — v1 has two

| Capability | Contract keys | Destination | Consumers today |
|---|---|---|---|
| `database.connection` | `POSTGRES_URL` | Secret | migration Job; units using a `postgres` resource |
| `kafka.connection` | `KAFKA_SASL_PASSWORD` | Secret | contract Job; units using a `kafka` resource |
| | `KAFKA_SSL_CA_CERT` | ConfigMap | trust material; not confidential |

**Admission rule for a third capability** (all three conditions): a Sol provisioner exists in
`platform/cloud`; at least one Sol-generated consumer exists; the contract keys are stable
enough to name. `cache.connection`, `objectstore.bucket` and `search.connection` fail today.

The rule is a **documented convention, not a runtime check**: a capability is a compiled
artifact — contract keys, a provider, and a projection — so one cannot exist without
code in those three places, and the rule is what that change is reviewed against. Default: not
yet.

## 2. Declaration

**Providers are declared on the target**, inside its existing entry in `sol/environments.yml` —
the same block as `cluster_name` and `profile`. No new file, no new section outside it.

```yaml
prod:
  targets:
    aws/us-east-1:
      cluster_name: pluto-prod
      capabilities:
        # Present only to bind an external database. Absent = the target provides the
        # database it already provisions (the workspace's postgres resource + the profile).
        database.connection:
          provider: external
          store: prod-db
          keys:
            POSTGRES_URL: pluto/app-db/url
        kafka.connection:
          provider: external
          store: prod-kafka
          keys:
            KAFKA_SASL_PASSWORD: kafka/workloads/password
            KAFKA_SSL_CA_CERT: kafka/workloads/ca
```

**The existing provisioner setting is the declaration; the capability block is external-only.**
`create_rds` is not a target field — the CLI derives it (`root_declared_vars ~has_postgres` in
`sol_cli_provider_capabilities.ml` sets `create_rds` from the workspace's declared resource and
the profile). A target that provisions a database therefore provides `database.connection`
without any declaration. `provider = sol` may be written but is never required, and writing it
duplicates nothing because there is nothing to duplicate: the block exists to *override*.

**External references are per contract key.** The existing authority type is already per key —
`External { store; key }`, held as `secret_authorities : unit → key → authority` — so a
capability whose contract has two keys names two remote paths. This is also the shape ESO
renders: one `ExternalSecret.data` entry per key, each with its own `remoteRef`. A single
`key:` for a multi-key capability would be unrenderable.

**Consumers require capabilities without naming a provider:**

- **Jobs are implicit.** Sol owns the migration Job's and contract Job's contracts.
- **Units use the existing graph.** `sol.yml` `resources:` declares the type (`postgres` →
  `database.connection`, `kafka` → `kafka.connection`) and `services[].uses` is the edge. No new
  DSL.

**The meeting point is plan time.** A required capability with no provider **fails at plan**, not
deploy. Where `provider = sol` but no provisioner exists for that capability (Kafka until a
generated credential lands), the plan fails naming the missing provisioner and the external
alternative — never deferring to a missing Secret at deploy.

## 3. Fulfillment

- **`sol`** — the value already exists as the target's Terraform output (`postgres_url` in
  `platform/cloud/{aws,gcp}/cluster/outputs.tf`). Sol projects it at **target install/reconcile**,
  never at app deploy.
- **`external`** — the target names an ESO store and a remote path per contract key; Sol renders
  a namespaced `ExternalSecret` into the app bundle's prerequisites (the existing external-secret
  path).
- The consumer is identical either way (§8.1).

### 3.1 One database per target

The consumer contract fixes the key name (`POSTGRES_URL`), so two `postgres` resources in one
target collide. **v1 is exactly one `database.connection` per target**; a second requirement
fails at plan, naming the constraint. Multi-database would require a capability to carry an
env-var mapping — a new surface, explicitly future work.

### 3.2 Projection objects are per capability *per namespace*

Kubernetes Secrets are namespace-scoped and a unit's `secretKeyRef` resolves in its own
namespace, so a target with consumers in three namespaces has **three projection objects per
capability** (for example three `sol-database-connection` Secrets), all produced from the same
source. It is *not* one object per target. Stating it here because "one per capability" is the
natural misreading and it breaks cross-namespace consumption.

## 4. Delivery quadrants

| | direct apply | GitOps (`--emit-to`) |
|---|---|---|
| **external** | the bundle carries the `ExternalSecret`; Sol waits for `Ready`/`SecretSynced`, plus the soft generation check | the same object is emitted; Argo and ESO reconcile it; Argo owns the wait |
| **sol** | the projection exists from target install; app deploy never writes it | **refused at plan in v1** (§4.1) |

Mode differences are only *who waits*. The emitted bytes are the contract.

### 4.1 GitOps with a Sol-provisioned capability is refused in v1

Under GitOps, Argo reconciles the namespace. A projection created by the target installation is
not in the app bundle, so Argo does not own it and nothing reconciles its drift — and v1 has no
controller that would. The plan refuses the quadrant and names both options: deploy directly, or
bind the capability to an external authority (which Argo *can* reconcile through ESO).

The v2 direction, once a reconciler exists, is an installation-owned projection with a stated
precondition. Not v1.

## 5. What this replaces

- `@platform/POSTGRES_URL`, `@platform/KAFKA_SASL_PASSWORD`, `@platform/KAFKA_SSL_CA_CERT` →
  capability projections. `@platform` addressing is removed and errors name the replacement.
- `default_secrets` → **deleted, not emptied.** It had two lives: the `secret_doc` base and
  `required_secret_keys`. Both go; the Kafka keys follow the capability requirement, so a unit
  that uses no `kafka` resource stops requiring them.
- `runtime_secret_name = "sol-secrets"` → one projection object per capability per namespace
  (§3.2), so each object has one owner.
- `SOL_API_KEY` is already a declared unit secret, not a workload default.

## 6. Lifecycle

- **Owner** — the target. Projections die with the target; applications never own them; an
  application rollback does not touch them.
- **Rotation, `sol`** — refreshed by target reconcile (re-reading the output). v1 requires
  re-running install/reconcile; automatic rotation is out of scope.
- **Rotation, `external`** — ESO semantics: source rotation needs a workload restart; a spec
  change is waited on softly.
- **Rollback** — re-renders the app bundle only; `external` projections re-render with it,
  `sol` projections are untouched.
- **Drift** — reconciled by the projection's writer: the installation for `sol`, ESO for
  `external`. Nothing application-side repairs it.

## 7. Moves and removals — report, never delete

Two cases share one rule.

- **`@platform` retirement.** The old `sol-secrets` object is not auto-deleted. Sol does not
  silently remove a populated object; the deploy reports it as unreferenced and the operator
  removes it.
- **Authority migration** (§8.8). When a key moves between `sol` and `external` — or a
  capability moves between providers — Sol **reports the object the move orphans** (the previous
  writer's Secret or `ExternalSecret`) and leaves it in place. It does not delete it, and it does
  not silently leave it either: the report names it, and the operator removes it.

This keeps every removal in the same discipline as resource ownership: Sol removes only what it
can prove it owns, and a populated object that may still hold a live credential is not proof.

## 8. Acceptance set — the implementation's review checklist

1. **Byte-equality** — the consumer's rendered spec is byte-identical under both providers, and
   the template contains no provider branch.
2. **No key without a consumer** — every projected key has a named consumer contract.
3. **Unit scope preserved** — a unit's Secret holds only its declared keys plus its capabilities'
   contract keys; no cross-unit leakage.
4. **Removals leave no dangling references** — dropping a capability or a key leaves no workload
   referencing a vanished key.
5. **Every new object has a named source** — each projected value has a producer (install output
   or ESO store), never a placeholder.
6. **Projections are never cached** — a projection is produced or read at its defined time; no
   stale copy is kept.
7. **All four quadrants are answered** — {direct, GitOps} × {sol, external}, per §4, with §4.1 as
   the v1 refusal.
8. **Authority migration is reported** — a move between providers reports the object it orphans
   (§7); no silent change and no silent deletion.

## 9. Out of scope

Multi-target sharing of a capability; resource CRUD independent of the target lifecycle;
capability types beyond database and Kafka; a new `resources:` DSL; automatic rotation;
cross-cloud portability; multi-database-per-target; and — for v1 — GitOps with a Sol-provisioned
capability.

## 10. Local development — a deliberate asymmetry

`cli/lib/local/sol_cli_local_run.ml` injects `POSTGRES_URL`, `SOL_API_KEY`, and the unit's
declared `[infra.env] secrets` into every local workload, and requires each to be present in
`sol/secrets.local/`. Kafka keys are **not** among them: local Kafka runs plaintext, so no SASL
credential or CA is projected locally — a unit that declares them is asking for them explicitly.

The asymmetry with the cluster is the point. Local runs have no workload identity, so they need a
universal plaintext fallback; production authenticates with workload identity and needs no
universal key. The hardcoded local list is not a leftover and must not be "fixed" to match the
cluster.
