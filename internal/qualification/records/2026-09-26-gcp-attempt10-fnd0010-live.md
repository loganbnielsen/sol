# GCP Attempt 10 — post-FND-0010 platform install, and the first blocker after it

**Outcome: the platform did not reach `Ready`.** `sol cloud apply` created the complete cloud
infrastructure (GKE `RUNNING`, Cloud SQL `RUNNABLE`) and then failed inside the platform layer:
cert-manager's post-install `startupapicheck` reached `BackoffLimitExceeded`. **The pre-fix
signature did not reproduce** — there is no `x509` line anywhere in the captured evidence, and
the check's own output is `error: timed out waiting for the condition` — so FND-0010's failure
mode is gone from this specimen while a different first blocker stands in its place: the check
pod's container started ~9 minutes after its image was pulled, so its 600s attempt window had
already elapsed before the check could run (FND-0060).

The supported destruction path then ran to completion on its own: preparation lowered the
deletion guards, the destroy **acquired only its declared temporary authority**, ran the platform
teardown, released the authority, destroyed the substrate, and left **both Terraform roots empty**
with the independent provider inventory reporting **absent** afterwards.

## Run identity

| | |
|---|---|
| Revision | `main @ bc9062b0` (REFAC-111, #546); `main` CI green at that SHA; working tree clean |
| Ancestors asserted present | FND-0010's merge `aac3f3ef`, INFRA-080's `3f1049f9` (both verified as ancestors before mutation) |
| Cluster | `sol-qual-gcp-10` |
| Target key | `qual10/gcp/us-central1` — its own; the fresh key's state objects were confirmed absent before the run, so nothing was inherited from Attempt 8 (`qual/…`) or the FND-0058 run (`qual9/…`) |
| Harness | `internal/qualification/gcp/live-qual.sh` at that revision; `LOG_DIR=/tmp/sol-gcp-qual-10`; `PHASE_TIMEOUT=2700` |
| Operator values | `IMPERSONATOR=user:lbendtlynielsen@gmail.com`, `LE_EMAIL=qualification@sol-harden-qualification.dev` |
| Bundle | `/tmp/sol-gcp-qual-10` (286 files) — inventory pre/post, both roots' state, the discriminator probes, `sol-runs/`, `cloud-apply.log`, `destroy.log` |
| Live window | 15:05:14Z → 15:36:41Z (**31 m 27 s**). Harness timestamps are local (UTC−6); all times below are UTC |

## Preflight (read-only, before any mutation)

Identity `lbendtlynielsen@gmail.com`; project `sol-qualification` `ACTIVE`, billing enabled;
`live-qual.sh verify` with the fresh cluster name: **19 disposable classes ABSENT, 2 durable
PRESENT, quota 0 usage, 0 UNKNOWN**; the fresh target's state objects absent
(`gs://sol-qualification-tfstate/sol/qual10/…` matched no objects); delegation resolving over DoH
(`ns-cloud-c1..c4`); the harness's own offline suite 124/124 and FND-0010's readiness guard with
all eight mutations rejected.

## Chronology (UTC)

| Time | Event |
|---|---|
| 15:05:14 | target written; durable root reconciled — *already matches its declared state*, nothing created |
| 15:05:24 | `CloudBootstrap` begins (`sol cloud apply`) |
| ~15:15:19 | `PlatformInstalling`: platform init, then the targeted apply of namespaces, provisioner RBAC and `helm_release.cert_manager` |
| 15:16:35 | `cert-manager-webhook-ca` secret created, `ca.crt` populated |
| 15:16:58 | `cert-manager-startupapicheck` Job created |
| ~15:17:5x | the check pod is Scheduled after transient `FailedScheduling` (untolerated taints / pod capacity); its image is pulled ~15:18 |
| ~15:27:35 | the check pod's **container is created and started** — ~9½ minutes after the image was pulled |
| ~15:27:37 | Job deletes the pod, `Killing`, then `BackoffLimitExceeded` |
| 15:27:42 | **`sol cloud apply` fails**: `failed post-install: job cert-manager-startupapicheck failed: BackoffLimitExceeded` |
| 15:27:5x | `provisioner-bootstrap-access-remove ok (9.4s)` — the install-time window closed on the failure path, before Sol reported the failure |
| 15:28:06 | discriminator captured (check log, events, job status, pods, webhook objects, firewall rules, master CIDR), classified by the harness as `SCHEDULING` (see the correction below) |
| 15:28:14–15:28:35 | pre-teardown independent inventory |
| 15:28:35–15:28:39 | **evidence frozen before teardown**: cloud/platform/durable state reads, 21 Sol run directories, inventory, classification, manifest |
| 15:28:39 | `sol cloud destroy qual10/gcp/us-central1` |
| 15:28:4x | `PreparingDestroy`: `gcp-destroy-prepare` lowered the Cloud SQL and GKE deletion guards |
| 15:28:5x | **authority acquisition**: plan with `-target=kubernetes_cluster_role_binding.provisioner_bootstrap_admin` (+ `google_sql_database_instance.postgres`, `google_container_cluster.main`, `-var=provisioner_bootstrap_admin=true`) → `[destroy-reconciliation-apply-plan] ok (9.3s)`, apply ok (3.4s) |
| 15:29:0x | **`platform-destroy` ok (77.3 s)** — the protected platform teardown ran |
| 15:29:1x | **authority release**: `[provisioner-bootstrap-access-remove-plan] ok (8.2s)` → apply ok (2.4s) |
| 15:29:2x | `Destroying`: substrate `terraform destroy` |
| 15:34:5x | `[terraform-destroy] ok (325.2 s)`; verification: *terraform state (disposable root): empty*; residue check **inconclusive** (the target declares no `gcp.project_id`, so the peering check did not run — reported, never read as absence); retention `none`. **`Done.`** — no degraded preparation |
| 15:36:41 | post-teardown inventory: **teardown verified: absent** |

## The cert-manager evidence (FND-0010's discriminator, and what it actually shows)

| Observation | Evidence |
|---|---|
| The pre-fix signature is absent | `rg 'x509\|certificate signed by unknown authority'` over the whole bundle: **no match**; the check's own output is one line, `error: timed out waiting for the condition` |
| The check ran rather than aborting early | Job `startTime 15:16:59Z`, conditions `FailureTarget/Failed = BackoffLimitExceeded`, `failed: 1` — where the pre-fix runs failed at 414s, this release was still waiting at **9m20s** |
| The CA material existed | secret `cert-manager-webhook-ca` present, `ca.crt` populated, created 15:16:35Z |
| The cert-manager pods were running at capture | controller / cainjector / webhook all `1/1 Running`, ages 11–12m |
| The check pod could not start for ~9½ minutes | events for `cert-manager-startupapicheck-xd44b`: `Scheduled` ~15:17, `Pulling`/`Pulled` ~15:18, then nothing until `Created`/`Started` ~15:27:35, then `SuccessfulDelete` → `Killing` → `BackoffLimitExceeded` |
| The node pool was under pressure during the burst | `FailedScheduling` warnings: `0/1 … 1 node(s) had untolerated taint(s)`, then `0/2 … 1 Too many pods, 1 node(s) had untolerated taint(s)`, then `0/3 … 1 Too many pods, 2 node(s) had untolerated taint(s)`; `TaintManagerEviction … Cancelling deletion of Pod` |

**Correction to the harness's classification.** The classifier labelled this `SCHEDULING` from those
`FailedScheduling` warnings, but their ages (11–12m at capture) equal the pods' ages: they are the
*initial* scheduling attempts, not a twelve-minute outage. The pods were placed within ~1 minute
and the real anomaly is the ~9½-minute delay between image pull and container start. The
classification should therefore be read as **`SCHEDULING`-adjacent but not established by the
events alone**: the bundle shows *that* the check could not run inside its window, not *why* the
container start was delayed. No instrument change was made during the run; the recommendation is
recorded in FND-0060.

## Supported destruction and the postcondition (provider API, not Sol's report)

| Evidence required | Result |
|---|---|
| Temporary authority bracket | observed: acquisition plan+apply → `platform-destroy ok (77.3s)` → removal plan+apply; the substrate destroy followed; **no degraded preparation**, `Done.` |
| platform Terraform state | **empty** — `resources=0, serial=5` at `sol/qual10/gcp/us-central1/platform.tfstate` |
| cloud Terraform state | **empty** — `resources=0, serial=16` at `sol/qual10/gcp/us-central1/cloud.tfstate` |
| Independent provider verification | harness verdict **`teardown verified: absent`**; 19 disposable classes ABSENT, including GKE/Cloud SQL/network/subnetwork/router/NAT/addresses/disks/forwarding rules/Artifact Registry/service accounts/role binding/peering; `quota: ABSENT (no usage)` |
| Non-ABSENT rows (recorded, not reinterpreted) | `service-account-provisioner` ABSENT *via an unreadable describe of a deleted identity*; `impersonator-binding` ABSENT *because the identity it is on is not active*; `custom-role` ABSENT *provider-deleted, kept in GCP's undelete window* — all three with the harness's own reason text, raw reads kept in the bundle |
| Durable prerequisites | state bucket `sol-qualification-tfstate` PRESENT; zone `qual-gcp-sol-fab-dev` PRESENT; delegation still resolving |
| Unexpected billable residue | none observed (`gcloud container clusters list` / `sql instances list` empty; quota 0) |
| Harness's own caveat | the residue check is `inconclusive` by design here (no `gcp.project_id` in the target, so the peering probe did not run) — reported, **not** read as absence |
| Emergency/manual action | **none** — every step above was a supported Sol command |

## What this run establishes

- A complete fresh GCP cloud infrastructure is created by the supported lifecycle, and the
  platform install reaches the cert-manager boundary (CloudBootstrap → platform prerequisites).
- **FND-0010's failure signature does not reproduce on current `main`**: the release is no longer
  aborted early, it waits, and the check's failure is its own timeout.
- The **failed-`PlatformInstalling` destruction path is reproduced on a second revision**: the
  authority bracket is acquired and released, the platform teardown runs, both roots end empty,
  and the independent inventory agrees.
- The install window closes on the failure path *before* Sol reports the failure.

## What this run does not establish

- **Nothing about `Ready`**, and therefore nothing about `Ready`-state destruction
  (`INV-DESTROY-1`'s `Ready` case). The destroy started from a failed install, as in the FND-0058
  run.
- **Nothing about TLS trust having been established**: the CA secret existed, but the bundle does
  not contain the webhook configuration's injected `caBundle`, and the check never reports a
  successful run. FND-0010's remedy is *unexercised to a successful conclusion*, so its state does
  not advance.
- Nothing about interrupted destruction, other providers, other starting states, or stale-state
  recovery.

## Instrument observations (recorded, not changed during the run)

1. `live-qual.sh verify` reaches `line 591: IMPERSONATOR: unbound variable` when `IMPERSONATOR`
   is not exported, aborting the inventory after 16 of 21 classes. It is documented as usable
   without the mutating phases' variables; either default it or require it explicitly.
2. The discriminator classifier attributes a cause from `FailedScheduling` warnings that may be
   long resolved (above). Capturing the check pod's container start timestamps and preferring
   recent events would make the classification evidence rather than inference.
