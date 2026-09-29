---
id: FND-0070
type: audit-finding
severity: high
source: qualification
---

# A failed apply leaves resources Terraform never adopted, and the destroy reports verified absence while they stand

## What happened

Attempt 25's `sol cloud apply` failed at the Cloud SQL instance — the provider timed out waiting for creation:

```text
│ Error: Error waiting for Create Instance:
│   with google_sql_database_instance.postgres,
```

The harness then ran the supported teardown. Sol reported:

```text
[terraform-destroy] ok (645.5s)
    residue Terraform does not own (controller load balancers, PVC volumes, abandoned peering): none found
Done. Destruction reached verified absence.
```

The provider says otherwise:

```text
$ gcloud sql instances list --project sol-qualification --format='value(name,state)'
sol-qual-gcp-25-postgres	RUNNABLE
```

and the harness's independent check agrees with the provider, not with Sol:

```text
  ✗ quota still exists (PRESENT) — non-zero usage
verify: resources remain
```

## Mechanism

The provider **created the instance anyway** and the create call still returned an error, so Terraform
recorded nothing in its state — the resource exists in GCP and is unknown to the state that the destroy
is driven by. Everything downstream then behaves consistently with that:

- `terraform destroy` is honest: it destroyed everything its state represented, including the network and
  the cluster, and reported success;
- the residue sweep found nothing, because on GCP it checks **one** class — the service-networking
  peering (`relinquished_residue_probes = ["google_service_networking_connection.sql", gcp_peering_probe]`) —
  while `aws_orphan_sweep` checks tag-derived load balancers and EBS volumes **and** has a gap path for a
  cluster name it cannot derive;
- the absence verdict is built from those two, so it concluded *verified absence*.

The consequence is exactly what the destruction contract forbids: **a claim of absence while a Sol-owned
resource stands**, and — worse — that resource is **unreachable by the supported destroy path**, because
the path acts on Terraform's state and the state does not know the resource exists. Attempt 25's SQL
instance is standing for that reason, and it also explains the 80 GiB `SSD_TOTAL_GB` reading that attempts
22 and 23 flagged: Cloud SQL storage counts against that quota.

## It has happened before

`sol-qual-gcp-15b` (an Artifact Registry repository, a reserved peering address and a provisioner service
account) is still in the project from an earlier attempt, and this is the most likely explanation for it
too. Both were reported rather than deleted; neither was created or left by the run that found it.

## Decision (2026-09-29): detect, refuse, name — then restore Terraform ownership

The operator decided: the immediate safety requirement is that such a resource is **PRESENT, not absent**,
and Sol must never report verified absence while it remains. Detect-and-refuse is not the terminal
behaviour: the long-term invariant is that every resource Sol causes Terraform to create stays
Terraform-owned or is deterministically recoverable into Terraform ownership, with Terraform remaining the
mutation authority and provider APIs the reality authority.

**Phase 1 (this work)** replaces the ad-hoc residue sweeps with a common absence contract behind two
provider inventories, so a discrepancy can no longer be reported as absence. See
`internal/qualification/records/2026-09-29-fnd0070-phase1-provider-inventory-and-live-regression.md`.

**Phase 2 (next)** restores Terraform ownership of an orphan through deterministic identity, and is
recorded with its evidence and constraints below.

## Earlier analysis: what is needed (a decision, not a mechanical fix)

**Detection is mechanical**: the GCP residue sweep should be brought up to the level the AWS sweep already
sets — name-addressed provider resources for the target's identity (the SQL instance named after the
cluster, the Artifact Registry repository, the reserved addresses, the service accounts and custom role,
the cluster itself), reported as residue when they exist and are not represented in state. That closes the
false claim.

**Reclamation is the decision.** A resource Terraform never adopted cannot be destroyed by the state-driven
path, so a supported command needs one of:

1. **Detect and refuse, report the orphan by name, and stop** — the destroy exits non-zero and names what
   stands, with reclamation left to the operator (safest, no new destructive authority);
2. **Adopt then destroy** — `terraform import` the named resource into the disposable root's state, then run
   the ordinary destroy against it (uses Terraform's own ownership, keeps one deletion path, but an import
   of a partially-created resource needs care);
3. **Reclaim by identity** — Sol deletes the named provider resource directly (most complete, but Sol gains
   provider-side deletion logic for resources it does not track, which the destroy design deliberately
   avoids today).

The finding is filed rather than fixed because option 3 in particular changes what a destroy is allowed to
do to something it never adopted, and because options 1 and 2 differ in who owns the risk of the delete.

## Evidence

| | |
|---|---|
| run | `/tmp/sol-gcp-qual-25` (attempt 25, revision `a30d54d4`) |
| Sol's claim | `Done. Destruction reached verified absence.` |
| provider | `sol-qual-gcp-25-postgres RUNNABLE` (still standing, deliberately) |
| independent check | `verify: resources remain` (`✗ quota still exists (PRESENT) — non-zero usage`) |
| state | the disposable cluster root's state is empty — the instance was never recorded |

## Phase 2 — ownership recovery (designed, not implemented)

The decision's invariant: **provider reality → deterministic attribution to the Sol target → deterministic
mapping to a Terraform address → restore Terraform ownership → the ordinary Terraform lifecycle.** No
parallel provider-side deletion: `gcloud … delete` for a resource Terraform should own is explicitly out.

**The mapping is deterministic for both live specimens, established rather than assumed:**

| provider resource | Terraform address (root) | import identity |
|---|---|---|
| `sol-qual-gcp-25-postgres` (Cloud SQL) | `google_sql_database_instance.postgres` | `projects/sol-qualification/instances/sol-qual-gcp-25-postgres` |
| `sol-qual-gcp-15b` (VPC network) | `google_compute_network.main` | the network name in the project |
| `sol-qual-gcp-15b-sql-peering` (reserved address) | `google_compute_global_address.sql_peering` | the address name |
| `sol-qual-gcp-15b` (Artifact Registry) | `google_artifact_registry_repository.images` | `projects/sol-qualification/locations/us-central1/repositories/sol-qual-gcp-15b` |
| `sol-qual-gcp-15b-provisioner@…` | `google_service_account.provisioner` | the account id |
| `sol_…_15b_cluster_access` (custom role) | `google_project_iam_custom_role.provisioner_cluster_access` | the role id |

**How the identity gets established, per the decision's four requirements.** Which target owns it: the
inventory's attribution rules (the target's own cluster name/tag/registry path) — never a broad naming
heuristic, and `Not_attributable` where it cannot be proven. Which logical resource it is: the mapping
above, one entry per `resource` block in the provider root, declared rather than derived by pattern
matching. Canonical provider identity: the import identity, derived from the cluster name. The address
that should own it: the root's own declared address, taken from the root rather than guessed.

**Ownership chains.** The distinction the decision asks for is already visible in the code and must be part
of the registry rather than implied:

- **direct** — Terraform declares it and can destroy it (`google_container_cluster.main`,
  `google_sql_database_instance.postgres`, …): recovery = import, then the ordinary destroy;
- **in-cluster** — Terraform declares it but it lives inside the cluster
  (`kubernetes_cluster_role_binding.provisioner_bootstrap_admin`): its absence follows from the cluster's,
  and it needs no recovery of its own;
- **controller-created descendants** — load balancers, disks, NEGs and forwarding rules that GKE/Kubernetes
  create in response to something Sol declares: recovery is **through the legitimate owner** (the
  Service/Ingress/PVC), never by importing the descendant into Terraform. This is why the inventory
  attributes forwarding rules by "inside the target's own VPC" and disks by `gke-<cluster>-*` rather than
  claiming every one of them;
- **external by contract** — the durable backend and the delegation zone: present by design.

**Fail-closed requirements for the import path.** Import only when the address, the provider identity and
the target all match exactly; refuse when the address already holds a resource, when another target claims
the identity, when the identity is ambiguous, or when the provider's own import semantics for that class
are not established. Never state surgery as an ordinary mechanism. Never delete an unknown resource
because its name resembles a Sol resource.

**Prevention (so this cannot recur for a new resource type).** The mapping must live with the resource
architecture, not in the qualification harness: an executable guard over each provider root, requiring
every `resource` block to carry a declared ownership kind and — for direct ones — an import identity and an
attribution rule. Adding a new directly-managed resource without a rediscovery strategy should fail CI.

## Phase 2 — implemented, and blocked at the import by the roots' own structure

**What is implemented and merged.** `sol cloud recover <TARGET>` (plan by default, `--apply` to import):
it resolves the provider's credentials the way destroy does, reads the independent inventory, maps every
resource it finds to a Terraform address through the identity registry, prints the mapping *with* its
reason, and imports only what the registry calls `Direct` with a recorded import identity. It refuses, with
the reason, when a class has no registry entry (`Unmapped`), when the registry marks it unrecoverable (a
composite provider identity, a module's internals, a workspace-dependent name), when two addresses match one
name (ambiguous), and when the state already owns the address. It verifies each import against the state
afterwards and fails if the provider id it adopted is not the identity it imported. Resources that are
external by contract, and resources a controller created on behalf of something Terraform owns, are reported
as such and never imported.

**Live, on Attempt 25's orphan** (`02:59Z`), the plan is exactly right:

```text
PRESENT: Cloud SQL instance sol-qual-gcp-25-postgres -- found sol-qual-gcp-25-postgres (the target's own
  cluster name …; checked with: gcloud --project sol-qualification sql instances list …)
  recover: Cloud SQL instance sol-qual-gcp-25-postgres maps to google_sql_database_instance.postgres,
  import identity sol-qual-gcp-25-postgres
  1 recoverable, 0 already owned, 0 not this target's to recover (contract or owner), 0 refused
```

**The import is refused by the configuration, not by Sol:**

```text
Error: Invalid provider configuration
  on …/platform/cloud/gcp/cluster/main.tf line 217:
 217: provider "kubernetes" {
The configuration for provider["registry.terraform.io/hashicorp/kubernetes"] depends on values that
cannot be determined until apply.
```

The cluster root declares its Kubernetes provider from the cluster's own attributes
(`host = "https://${google_container_cluster.main.endpoint}"`). When the cluster is gone, that value is
unknown, so **`terraform import` — which must evaluate the whole configuration — cannot run in this root at
all**, while `terraform destroy` can (it only needs the providers its state's resources use, which is why
the destroy path works today). This is the counterexample the decision asked to be surfaced rather than
worked around: importing a substrate resource is blocked by provider configuration that belongs to a
different lifecycle stage.

**Alternatives, with their trade-offs** (a decision, not a mechanical fix):

1. **Put the in-cluster resources behind a counted module** (`count = var.cluster_exists ? 1 : 0`). When the
   cluster is absent the module is disabled and its provider is never configured, so import works in the
   same root and state — Terraform keeps ownership throughout. Costs a structural change to the cluster root
   and a variable the apply must set; the desired configuration of the imported resource is unchanged.
2. **A separate substrate-only root** for the resources that do not need the cluster. Cleanest separation of
   the two lifecycles, but it moves addresses and state, and it duplicates part of the graph today.
3. **Operator recovery**: delete the orphan at the provider under explicit authorization. It restores
   nothing to Terraform and is outside Sol's authority by design, but it is immediate.
4. **Leave it.**

**`sol-qual-gcp-25-postgres` therefore stands**, deliberately, pending that choice. Nothing was imported,
nothing deleted, no state was edited.

## `sol-qual-gcp-15b` — established, and deliberately not destroyed

Its own state exists (`gs://sol-qualification-tfstate/sol/qual15b/gcp/us-central1/cloud.tfstate`, serial 6)
and already owns the resources the inventory found, under the *current* address names
(`google_compute_network.main`, `google_compute_global_address.sql_peering`,
`google_artifact_registry_repository.images`, `google_service_account.provisioner`,
`google_project_iam_custom_role.provisioner_cluster_access`, and the rest) — so 15b needs **no import at
all**: the ordinary supported destroy of *its own* target is the right path.

It was not run, for a reason worth recording: that state also contains
`google_compute_default_service_account.default` — the **project's default compute service account**,
declared inside the module — and `terraform destroy` is unscoped, so it would delete a project-wide resource
that is not 15b's residue. Per "fail closed rather than guessing", the destroy was left unrun; a targeted
destroy, a module-scoped state, or explicit authorization to remove it are the options.

## Option 1 implemented — and the live proof stops one step short, at a different defect

**The mechanism.** `in_cluster_layer` (bool, default `true`) is an *operation-scoped* input, not a
claim about GKE: `local.needs_kubernetes = var.in_cluster_layer && var.provisioner_bootstrap_admin`
gates the Kubernetes provider and the bootstrap binding. The provider now takes `host`, `token` and
`cluster_ca_certificate` from three locals that are the **empty string** when the layer is off — a
*known* value — and reads the cluster through a `count`-gated data source instead of the resource it
creates. No address changed, no state migrated: the same root, the same state, the same resource
addresses. Sol passes `in_cluster_layer=false` for recovery and teardown.

Two facts settled the design by experiment, in `/tmp` against a copy of the real root:

- **Gating the resource is not enough.** `provisioner_bootstrap_admin` already defaults to `false`, so
  the binding's `count` was already 0 — and `terraform import` still failed with the provider error.
  Terraform configures the root's provider whether or not a resource uses it.
- **A counted module containing a provider is refused**: *"Module is incompatible with count,
  for_each, and depends_on"*. That closes the counted-module route the decision proposed exploring.

Coverage: `check_substrate_root_evaluable.py` (structural: the provider's values come from the gated
locals, the gate is the conjunction, every in-cluster object carries it) runs in CI;
`check_substrate_root_evaluable.sh` is the behavioural half — `terraform console` proves the three
locals are a known empty string with the layer off and `needs_kubernetes` is true with it on.

**The live result, Attempt 25 (`03:48Z`).** The import now succeeds:

```text
  importing sol-qual-gcp-25-postgres as google_sql_database_instance.postgres (identity sol-qual-gcp-25-postgres)...
    google_sql_database_instance.postgres now owns sol-qual-gcp-25-postgres
1 resource(s) brought back under Terraform ownership.
```

and a second run is idempotent — `already owned: sol-qual-gcp-25-postgres is already in this root's
state (google_sql_database_instance.postgres)`, `0 recoverable, 1 already owned, 0 refused`, exit 0.

**The destroy does not converge, for a reason that is not FND-0070.** The instance's
`deletion_protection` is `true` at the API, so the ordinary destroy needs Sol's guard-lowering
preparation first. That preparation's plan — necessarily the target's dependency closure — wants to
**create** `google_compute_network.main`, `google_compute_global_address.sql_peering` and
`google_service_networking_connection.sql`, because the instance's network and peering were destroyed
in an earlier teardown. A teardown preparation must not create infrastructure, so the refusal is
correct, the guard is never lowered, and `terraform destroy` then fails:

```text
Error: Error, failed to delete instance because deletion_protection is set to true.
error: Destruction did not converge: terraform exited 1
```

Terraform cannot flip that attribute during a destroy, and `-target` cannot isolate it because
targeting a resource includes its dependencies' creates. One change was needed and is in this branch:
`private_network` is now expressed from `var.project_id`/`var.cluster_name` (the same value the
resource's `id` produces, with an explicit `depends_on` keeping the ordering) instead of from
`google_compute_network.main.id`, which was *unknown* while the network was absent and therefore forced
a **replacement** of a live instance. With that, the plan is replace-free; the remaining blocker is
purely the guard.

**The options, for a product decision** (this is the stop):

1. Let a *destroy-time* preparation apply guard-only changes even when its plan includes creating the
   resource's absent dependencies — reconciling what is about to be deleted, against the standing
   "during destruction the desired state is absence".
2. Have Sol lower a deletion guard through the provider's own API (a patch, not a delete) when the
   guarded resource is being destroyed and Terraform cannot reach it — provider-side *guard* action,
   never provider-side deletion of an orphan.
3. Operator action: lower the guard on this one instance, then run the supported destroy, which then
   converges.

## The project's default compute service account — a correction

I first reported that `sol-qual-gcp-15b`'s state holds the project's default compute service account and
that an unscoped destroy would delete it. **That was wrong**, and the way it was wrong is the reason this
section exists. The state entry is `mode: data`:

```text
$ jq -r '.resources[] | "\(.mode)\t\(.type).\(.name)"' qual15b-state.json | sort -u
data    google_client_config.default
data    google_compute_default_service_account.default
managed google_artifact_registry_repository.images
managed google_compute_network.main
...
```

A data-source record is not ownership, and an ordinary destroy does not touch it. The root reads the
account to grant the node identity registry access (`gke_node_service_account` resolves the node pool's
`"default"` to that address, REFAC-100), which is the correct shape: GKE nodes use the project's default
compute service account unless a dedicated one is configured, so Sol needs its email and must not own it.

My earlier `jq` printed only the type and name, dropping the field that carries the distinction, and I
concluded from that. `check_project_shared_resources.py` now keeps the config-side invariant that makes the
state-side fact true — no target may *manage* a project-wide resource, and each must be *read* — with the
mutation that reintroduces managed ownership rejected. The unnecessary `removed` block I added on the
strength of the wrong reading is gone.

15b was still not destroyed, and for a reason that survives the correction: its own SQL instance would meet
the same deletion-guard blocker as Attempt 25, and a half-teardown is worse than a whole one.

## What Attempt 25 actually was, and what that leaves

**The trace.** `sol cloud apply` started 22:28:05Z; GCP's `CREATE` operation for the SQL instance ran
22:29:41.617Z → **22:37:34.845Z, `DONE` with no error**; Terraform exited 1 at 22:39:11Z — 96s *after*
GCP had succeeded — with `Error waiting for Create Instance: ` and nothing after the colon. The target's
cloud state afterwards held **0 resources**. So the orphan was not a GCP failure and not Sol's: the
provider's wait reported a failure the provider had no message for, and on that path it calls
`d.SetId("")` before returning, so Terraform recorded nothing.

**Why the message was empty.** `SqlAdminOperationError.Error()` builds its text from
`OperationErrors.Errors`; when GCP returns an error object with no entries it returns `""`, and the shared
waiter wraps it as `Error waiting for %s: %w`. An empty message, by construction.

**There is nothing to upgrade to.** `google/services/sql/sqladmin_operation.go` and
`google/tpgresource/common_operation.go` are **byte-identical between v5.45.2 and v6.20.0**, and v6.20.0's
create path still calls `d.SetId("")` on a failed wait and still defaults `deletion_protection` to `true`.
Upstream tracks it as open issues (#25234 "`OperationWait`: `err` gives us no error output despite
`err != nil`", #27922). "Upgrade past the waiter bug" is not available; the class is what it is, and it is
an *ambiguous remote outcome*, not a provider bug with a released fix.

**The guard was never in GCP.** `settings.deletionProtectionEnabled` is `false` on the live instance, while
the imported state's `deletion_protection` is `true`: that attribute is provider-only, is not read from the
API, and import leaves it at the schema default. `apply -refresh-only` does not change it. So a destroy
refused because Terraform's own bookkeeping said so, and clearing it needed an apply whose plan for the
instance also **creates** its absent dependencies ("3 to add, 1 to change") — reconciliation toward
presence during a teardown.

## Classification of the FND-0070 machinery, and what was cut

| piece | verdict |
|---|---|
| `Sol_cli_absence` (ABSENT/PRESENT/UNKNOWN, attribution, residue, report) | **kept** — the independently verified postcondition; a successful Terraform command is not proof of provider reality |
| the two provider inventories (16 + 15 classes) | **kept** — independent observation of provider reality, and the tool that made this cleanup possible |
| the identity registry's adoptable mappings (address, class, observed name, import identity) | **kept** — the exact join adoption needs for an ambiguous outcome |
| `in_cluster_layer` and the root restructuring | **kept** — small, and required for a substrate adoption to be evaluable while the cluster is absent, which an ambiguous outcome can leave behind |
| the recurrence guard + mutation tests | **kept, simplified** — a declared resource with no mapping, a mapping without an import identity, a mapping naming a class no inventory reports, a stale entry |
| `descendants`, `class_rules`, `Through_owner`, `source` | **removed** — a taxonomy of *why* something is not adoptable, earning nothing once adoption is restricted to exactly-attributable directly-managed resources; an unlisted class is reported and never adopted, which is already fail-closed |
| the class-coverage check ("every class the verifier reports has a recovery story") | **removed** — it forced an entry for every class, including ones that are never adoptable |
| `private_network` expressed from the target's inputs, and the extra `depends_on` | **reverted** — introduced only so the guard-clearing plan would not also want a replacement; that chain is gone |
| any provider-side mutation or deletion fallback in Sol | **never added** — disposal of the historical specimen was a one-time operator-authorized act, outside the product |

Simplified: 138 mappings still, but the registry loses two lookup tables and two constructors, and the
reconciler loses a disposition case and two parameters.
