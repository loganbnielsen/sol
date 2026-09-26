# GCP FND-0058 live qualification — 2026-09-26

**Outcome: FND-0058 is qualified live.** A fresh target whose platform install failed (`cert-manager`,
FND-0010's known failure) was destroyed by `sol cloud destroy` alone: the destroy **reacquired only its
declared temporary authority** (the plan record shows
`kubernetes_cluster_role_binding.provisioner_bootstrap_admin[0] will be created`, and the apply reports
`Resources: 1 added, 0 changed, 0 destroyed`), **ran the platform teardown that Attempt 8 skipped**
(`platform-destroy ok, 77.2 s`), removed the authority, destroyed the substrate, and left **both
Terraform roots empty** (platform 0 resources, cloud 0 resources). Attempt 8's degradation — "the
platform teardown was skipped because the bootstrap authority it needs could not be obtained" — did
not occur: this run ends `Done.`, with no degraded preparation.

**Cost exposure at close: zero billable residue**, verified independently; the durable prerequisites
are intact and the delegation still resolves. Attempt 8's preserved state, worktree and bundle were
not touched.

## Run identity

| | |
|---|---|
| Cluster | `sol-qual-gcp-9` |
| Target key | `qual9/gcp/us-central1` — **its own**, never Attempt 8's, so this run produced its own specimen and could not inherit or overwrite the preserved state (`INFRA-084`) |
| Revision | `main @ 67bdef8e`; `sol --version` = `67bdef8e`, asserted equal to the worktree HEAD; working tree clean |
| Harness | `internal/qualification/gcp/live-qual.sh` at that revision; `LOG_DIR=/tmp/sol-gcp-qual-9-attempt`; `PHASE_TIMEOUT=2700` |
| Operator values | `IMPERSONATOR=user:lbendtlynielsen@gmail.com`, `LE_EMAIL=qualification@sol-harden-qualification.dev` |
| Live window | 01:39:58Z → 02:06:44Z (**26 m 46 s**) |

## Preflight (read-only, before any mutation)

Identity `lbendtlynielsen@gmail.com`; project `sol-qualification` `ACTIVE`, billing enabled; the
**fresh target's state objects absent** (cloud, platform); `live-qual.sh verify`: **19 disposable
classes ABSENT, 2 durable PRESENT, quota 0, 0 UNKNOWN**; delegation resolving
(`ns-cloud-c1..c4`); no operation record for this target's roots; revision/binary match PASS.

## Chronology (UTC)

| Time | Event |
|---|---|
| 01:39:23 | `PLAN_ONLY`: durable root already matches its declared state; `cloud-plan` ok; **nothing created** |
| 01:39:58 | `CloudBootstrap` begins (`sol cloud apply`) |
| 01:50:26 | `terraform-apply` **ok (628.3 s)** — GKE `RUNNING`, Cloud SQL `RUNNABLE` |
| 01:50:27 | `PlatformInstalling`: platform init ok (6.7 s); targeted apply of the namespaces, the provisioner RBAC and `helm_release.cert_manager` |
| 01:57:41 | **`platform-prerequisites-apply` FAILED (414.1 s)** — cert-manager's post-install check, exactly as in Attempts 4/5/8 |
| 01:57:5x | `provisioner-bootstrap-access-remove` **ok (10.6 s)** — the install-time window was closed on the failure path, before Sol reported the failure |
| 01:58:0x | discriminator captured and classified: **`TLS_CA_OR_CERTIFICATE`** |
| 01:58:33 | pre-teardown independent inventory captured |
| 01:58:36 | **evidence frozen before teardown**: cloud/platform/durable state, 21 Sol run directories, inventory, classification, manifest → then `sol cloud destroy qual9/gcp/us-central1` |
| 01:58:5x | `PreparingDestroy`: `gcp-destroy-prepare` lowered the Cloud SQL and GKE deletion guards |
| 01:58:59 | **authority acquisition plan**: `-target=kubernetes_cluster_role_binding.provisioner_bootstrap_admin -target=google_sql_database_instance.postgres -target=google_container_cluster.main -var=provisioner_bootstrap_admin=true` — plan record: **`kubernetes_cluster_role_binding.provisioner_bootstrap_admin[0] will be created`** |
| 01:59:10 | `[destroy-reconciliation-apply-plan] ok (9.9 s)` — **permitted** (Attempt 8 was refused here) → apply **ok (4.5 s)**; record: `Creating...`, `Creation complete after 0s`, **`Apply complete! Resources: 1 added, 0 changed, 0 destroyed`** |
| 02:00:2x | **`platform-destroy` ok (77.2 s)** — the protected teardown ran, with the authority |
| 02:00:38 | **authority removal plan**: `-target=…provisioner_bootstrap_admin -var=provisioner_bootstrap_admin=false` → record: `…[0] will be destroyed (because index [0] is out of range for count)` |
| 02:00:50 | `[provisioner-bootstrap-access-remove-plan] ok (11.0 s)` → apply ok (3.3 s); record: `…[0]: Destroying...`, `Destruction complete after 0s` |
| 02:00:54 | `Destroying`: substrate `terraform destroy` |
| 02:06:0x | **`terraform-destroy` ok (324.5 s)**; verification: *"terraform state (disposable root): empty"*; residue check reported inconclusive (the target declares no `gcp.project_id`, so the peering check did not run — reported, never read as absence); retention `none`. **`Done.`** — no degraded preparation |
| 02:06:44 | post-teardown inventory; the target file was kept because two classes did not read ABSENT (below) |

## The destruction precondition, from the frozen bundle

| Condition | Evidence (all frozen before the destroy) |
|---|---|
| lifecycle = failed `PlatformInstalling` | `[platform-prerequisites-apply] FAILED (414.1 s)` |
| install-time authority closed | `provisioner_bootstrap_admin=false` in the removal apply, `[provisioner-bootstrap-access-remove] ok (10.6 s)` |
| platform state non-empty | `state/platform.tfstate`: **11 resources**, serial 3 |
| substrate state non-empty | `state/cloud.tfstate`: **18 resources**, serial 7 (cluster + Cloud SQL present) |
| provider-side cluster exists | `inventory-pre.tsv`: `gke-cluster PRESENT`, `sql-instance PRESENT` |
| no unrelated reconstruction | the acquisition apply acted on **one** resource — the authority |

## The authority bracket, live

```
authority absent before acquisition   (window closed by the failed install; cloud state has no binding)
acquisition planned + permitted       plan record: …provisioner_bootstrap_admin[0] will be created
acquisition applied                   …[0]: Creating... Creation complete … 1 added, 0 changed, 0 destroyed
authority present for the teardown    platform-destroy ok (77.2 s) — it cannot succeed without cluster-admin
removal planned + applied             …[0] will be destroyed (index out of range) → Destroying... complete
post-removal observation              binding absent from the substrate destroy's actions; cloud state empty
```

## Postcondition (provider API, not Sol's report)

| Must be absent | Result |
|---|---|
| GKE cluster, Cloud SQL instance | absent |
| network, subnetwork, router, NAT, addresses (regional and global), disks, forwarding rules | absent |
| Artifact Registry repository | absent |
| service accounts (loki, thanos) | absent |
| `role-binding`, peering | absent |
| quota usage | `0` |
| **non-ABSENT, with recorded semantics (`INFRA-080`)** | `service-account-provisioner` **UNKNOWN** and `impersonator-binding` **UNKNOWN** (GCP answers `PERMISSION_DENIED … (or it may not exist)` for a deleted service account; the probe refuses to read that as absence — fail-closed by design); `custom-role` **PRESENT** with `deleted: true` — GCP soft-deletes custom roles into an undelete window (non-billable). All three were filed before this run and were reproduced exactly; no interpretation was improvised. |

| Must be present | Result |
|---|---|
| GCS state bucket `sol-qualification-tfstate` | present |
| Cloud DNS zone `qual-gcp-sol-fab-dev` + delegation | present; `NS → ns-cloud-c1..c4` still resolving |

| Terraform state | Result |
|---|---|
| cloud root (`sol/qual9/…/cloud.tfstate`) | **empty** — 0 resources, serial 16 |
| platform root (`sol/qual9/…/platform.tfstate`) | **empty** — 0 resources, serial 5 |

## What this run establishes

- **FND-0058's fix works live**, in the exact state that exposed it: the instance-qualified authority
  `CREATE` is expressible, permitted, and applied; the platform teardown runs; the authority is
  removed; both roots end empty. The failed-`PlatformInstalling` case of `INV-DESTROY-1` is satisfied.
- **The live negative invariant held:** *authority `CREATE` → allowed; target `CREATE`/`REPLACE` →
  none.* The acquisition apply's own record is `1 added, 0 changed, 0 destroyed`.
- **The failure-path window closure still works** (`provisioner-bootstrap-access-remove ok, 10.6 s`
  before the failure was reported), so the destroy reacquired authority from a genuinely closed window
  rather than inheriting an open one.
- **The evidence model held**: classification, both roots' state, Sol's run artifacts and the
  independent inventories were captured **before** the destructive steps, and an independent sweep
  afterwards agrees with them for every billable class.

## What this run does not establish

- **Nothing about `Ready`-state destruction**: the destroy started from a failed install, not from a
  healthy platform. `INV-DESTROY-1`'s other cases (`CloudBootstrap`, `Ready`, interrupted destruction)
  remain unobserved.
- **Nothing about FND-0010** beyond reproducing its known failure class (`TLS_CA_OR_CERTIFICATE`,
  recorded as the specimen's provenance). No remediation was attempted.
- **Nothing about FND-0059**: its subject (a declared guarded address versus Terraform's instanced
  address) is AWS-side; the GCP guarded resources are uncounted, so the run could not exercise it.
- **The authority acquisition plan JSON is not retained** by Sol (SEC-008: plan JSON never reaches the
  run log). The instance-qualified create is evidenced instead by the product's own durable operation
  records above, and by contrast with Attempt 8's refusal of the same plan shape.

## Evidence

Bundle: **`/tmp/sol-gcp-qual-9-attempt`** (70 files) — `evidence-manifest.txt`,
`fnd0010-classification.txt` + its probes, `state/{cloud,platform,durable}.tfstate`, `sol-runs/`
(21 directories), `inventory-pre.tsv`, `inventory-post.tsv`, `cloud-plan.log`, `cloud-apply.log`,
`destroy.log`. Durable supervision records for this run:
`~/.local/share/sol/operations/gcp-cluster-38c03e982439fdf1/*` (prepare, acquisition, removal,
substrate) and `gcp-platform-ead0ccf85429eace/*` (platform teardown), each with stdout, stderr and an
`exit` record. Attempt 8's bundle and preserved state are untouched.
