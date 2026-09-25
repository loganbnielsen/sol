# GCP Attempt 8 — 2026-09-25

**Outcome: it reached the question it was sent to answer.** `sol cloud apply` failed at
cert-manager's post-install check as in Attempts 4–5, and the harness captured the
discriminator **before any teardown**. The classification is `TLS_CA_OR_CERTIFICATE`: the
webhook was reachable and served TLS, the API server rejected its certificate, and the
webhook configuration's `caBundle` was uninjected at the time of the check. That
**falsifies the reachability hypothesis FND-0010 had been carrying** — a firewall rule for
the control plane would not address a trust failure. The platform did not reach `Ready`.

**Cost exposure at close: zero billable residue**, verified independently two-sided. One
degraded step remains and is filed as **`FND-0058`**: the destroy **skipped the platform
teardown**, leaving the platform Terraform state stale (11 resources) after the cluster it
described was gone.

This run continues the Phase-0 stop recorded in
`2026-09-25-gcp-attempt8-phase0-stop.md` (`main @ 1aad2623`, `STOPPED_PHASE_0`, no
mutation), after the corrective PRs **#514** (`50449a1a`, filing) and **#516** (`dae9540d`,
fix).

## Run identity

| | |
|---|---|
| Cluster | `sol-qual-gcp-8` |
| Revision | `main @ dae9540d`; `sol --version` = `dae9540d`, asserted equal to the worktree HEAD before launch |
| Harness | `internal/qualification/gcp/live-qual.sh` at `dae9540d`; `LOG_DIR=/tmp/sol-gcp-qual-8-attempt`; `PHASE_TIMEOUT=2700` (the default 1200 s is shorter than cloud root + platform install) |
| Operator values | `IMPERSONATOR=user:lbendtlynielsen@gmail.com` (active account, `roles/owner`), `LE_EMAIL=qualification@sol-harden-qualification.dev` (the address recorded as verified live against ACME) |
| Delegation | already live (`qual-gcp.sol-fab.dev NS → ns-cloud-c1..c4`), so no human step was needed |
| Phase 0 | re-run on the corrected harness immediately before the attempt: **19 disposable classes ABSENT, 2 durable PRESENT, quota 0, 0 UNKNOWN**, and — with a target file present — a **failing** `verify` was demonstrated to invoke no teardown (`rc=1`, no `destroy.log`, target retained) |

## Chronology (UTC)

| Time | Event |
|---|---|
| 21:56:47 | Phase 0 revalidation begins (read-only provider reads only) |
| 21:58:35 | `PLAN_ONLY`: durable root "already matches its declared state"; `cloud-plan` ok (15 s); **nothing created** |
| 22:00:57 | target written; durable reconcile ok; `CloudBootstrap` begins |
| 22:01:03 | NS hand-off printed immediately (the zone already exists) |
| 22:11:05 | `terraform-apply` **ok (579.7 s)** — GKE `RUNNING`, Cloud SQL `RUNNABLE` |
| 22:11:06 | `PlatformInstalling`: platform init ok (5.3 s); targeted apply of the five namespaces, the provisioner RBAC, and `module.platform.helm_release.cert_manager` |
| 22:18:0x | `platform-prerequisites-apply` **FAILED (416.7 s)** — "Helm release \"\" was created but has a failed status"; the check itself timed out after `1m0s` with `x509: certificate signed by unknown authority` |
| 22:18:1x | `provisioner-bootstrap-access-remove` **ok (12.9 s)** — the install window was closed on the failure path *before* Sol reported the failure, so FND-0047's leaked-elevation trap did not occur |
| 22:18:40 | discriminator capture: 12 probes (check logs, job status/describe, events, pods, cert-manager objects, webhook targetPort, webhook endpoints, webhook configuration, nodes, firewall rules, master CIDR) |
| 22:18:49 | pre-teardown independent provider inventory |
| 22:18:53 | **evidence frozen before teardown**: cloud/platform/durable Terraform state, 21 Sol run directories, inventory, classification, manifest |
| 22:18:53 | teardown: `sol cloud destroy qual/gcp/us-central1` |
| 22:19–22:25 | window close ok (3.1 s); `terraform destroy` **ok (367.6 s)** |
| 22:25:5x | verification: **degraded** — platform teardown skipped; cloud state empty; residue check *inconclusive* (the target declares no `gcp.project_id`, so the peering check did not run — reported, never read as absence); retention `none` |
| 22:26:22 | post-teardown inventory: **teardown NOT verified** (2 of 21 classes) |
| 22:37 | independent sweep by the operator-facing command set: nothing billable remains; peering none; durable intact |

Live infrastructure was up **22:01:03Z → 22:26:22Z (25 m 19 s)**; total elapsed for the
attempt including preflight and capture, 22:00:57Z → 22:26:22Z.

## The discriminator — the run's primary output

```
classification: TLS_CA_OR_CERTIFICATE
```

The check's own words, captured before teardown
(`fnd0010-startupapicheck-logs.log`):

```
"Not ready" logger="cert-manager.checkAPI" err="Internal error occurred: failed calling webhook
\"webhook.cert-manager.io\": failed to call webhook: Post
\"https://cert-manager-webhook.cert-manager.svc:443/validate?timeout=30s\": tls: failed to verify
certificate: x509: certificate signed by unknown authority"
…
"Timed out" logger="cert-manager.checkAPI" after="1m0s" err="context deadline exceeded"
```

Corroboration captured in the same freeze:

| Observation | Value |
|---|---|
| webhook Service endpoints | `cert-manager-webhook 10.1.0.78:10250` — live, on the node subnet |
| webhook `targetPort` | `https` |
| `ValidatingWebhookConfiguration` (created 22:11:41Z) | carries `cert-manager.io/inject-ca-from-secret: cert-manager/cert-manager-webhook-ca`, and **no `caBundle` field was present** at capture time |
| cert-manager pods | `cert-manager`, `cainjector`, `webhook` all `1/1 Running` — but each had `FailedScheduling` for ~1 min first ("1 node(s) had untolerated taint(s)", "Too many pods") and were only ~5 m 44 s old at capture |
| `startupapicheck` pod | `0/1 Error`, 3 restarts |
| master CIDR | `172.16.0.0/28` |
| firewall rules | only the GKE-default node rules (`10.0.0.0/20`, `10.1.0.0/16`) |

**FACT.** The API server *reached* the webhook: the failure is a completed TLS handshake
whose certificate was untrusted. A connection failure reads `context deadline exceeded`,
`dial tcp`, `connection refused` or `no route to host` — none appear anywhere in the capture
**FACT.** The webhook Service had live endpoints on the node subnet at capture time, so
reachability is not what failed.
**FACT.** The webhook configuration's `caBundle` had not been injected when the check ran.
**INFERENCE (not a fact).** The trigger is cert-manager's own startup ordering under
Autopilot scheduling: the pods were held about a minute by node taints and pod-count limits,
so the post-install check ran while the CA bundle was still uninjected. Whether the check
would have passed had it waited longer is **not established** — helm retried and gave up
first.
**HYPOTHESIS FALSIFIED.** "The GKE control plane cannot reach the cert-manager webhook on
port 10250 / needs a firewall rule for the master CIDR." The call reached the webhook; the
defect is certificate trust, not connectivity. No firewall rule was added, deliberately.

## Postcondition (provider API, not Sol's report) — 22:37Z

| Must be absent | Result |
|---|---|
| GKE cluster, Cloud SQL instance | absent |
| Target network / subnetwork / router + NAT / addresses (regional and global) / peerings | absent (only the project's `default` network remains) |
| Disks, forwarding rules, Artifact Registry repository | absent |
| Target service accounts (provisioner, loki, thanos) | absent |
| Quota usage (`CPUS`, `IN_USE_ADDRESSES`, `SSD_TOTAL_GB`, `DISKS_TOTAL_GB`, `INSTANCES`) | `0` |

| Must be present | Result |
|---|---|
| Cloud DNS zone `qual-gcp-sol-fab-dev` (durable, DEC-043) | present, delegation still resolving |
| GCS state bucket `sol-qualification-tfstate` | present |

| Residue | Result |
|---|---|
| Terraform state, cloud root | **empty** (0 resources, serial 47) — Terraform's destroy is the authority for what it manages (DEC-045) |
| Terraform state, platform root | **11 resources still recorded** (6 namespaces, `helm_release.cert_manager`, 4 RBAC objects) while the provider reality is gone — the teardown was skipped, see `FND-0058` |
| IAM custom role | `deleted: true` (GCP's undelete window; non-billable). Attempts 5, 6 and 8 all linger here; Sol's destroy did delete each |
| `impersonator-binding` | **UNKNOWN** — the provider answers `PERMISSION_DENIED: … (or it may not exist)` for a deleted service account, so the harness refuses to call it absent (fail-closed, by design) |

## What this attempt establishes

- **FND-0010's cause is no longer a hypothesis to be re-tested by repeating the run**: it is
  a certificate-trust/startup-ordering failure inside cert-manager's own admission webhook,
  with reachability excluded by the webhook's live endpoints and the completed handshake.
- **`sol cloud apply` ran end to end on the current implementation**: durable reconcile →
  cloud apply (579.7 s) → install window opened (`provisioner_bootstrap_admin=true` in the
  plan argv) → platform install → readiness refused → window closed (12.9 s) → failure
  reported. The four Terraform operations ran under the **supervisor**, each with a durable
  operation record (`gcp-a11b06df28073ace`, `base-gcp-30f466d00a3100e5`) and an exit record
  (INFRA-076, exercised live).
- **The install window is closed on the failure path** (INV-AUTH-3's failure branch):
  `provisioner-bootstrap-access-remove ok (12.9 s)`, and the destroy's own reconciliation
  confirmed the window closed again before destroying.
- **`destroy_retention: none` reached Terraform on GCP**: `-var=gcs_soft_delete_retention_seconds=0`
  in the applied plan (FND-0057's fix, live).
- **The durable prerequisites survived a real destroy** with `create_dns_zone=false`
  (DEC-043), and the delegation still resolves.
- **The evidence model held under a real failure**: the classification, both roots' state,
  Sol's run artifacts, and the independent inventories were all captured **before** the
  teardown, and an independent sweep afterwards agrees with them for every billable class.

## What this attempt does not establish

- **Nothing about `Ready`.** The platform install failed at its first component; no row that
  needs a running platform (`INV-SUBSTRATE-*`, `INV-IDENT-1`, ingress, messaging,
  observability) is advanced.
- **Nothing that closes FND-0010.** The cause is established; the fix is not designed here,
  and no remediation was attempted during the run (by authorization).
- **`INV-DESTROY-1` is not satisfied for the failed-`PlatformInstalling` case**: the destroy
  ran but degraded (`FND-0058`), so the row's own precondition ("both Terraform destroys
  return success") did not hold. `INV-DESTROY-4` likewise: the *cloud* root reached absence
  and was queried class by class; the platform root did not.
- **FND-0029's shape** (a target that declares an issuer, applied then destroyed unedited) was
  deliberately not exercised: this target declares no `cluster_issuer`.
- **Public TLS** (FND-0007) — not reached, not claimed.
- The `custom-role` and `impersonator-binding` postconditions were not *verified* clean; both
  are explained above, and neither is billable.

## Evidence

Bundle: **`/tmp/sol-gcp-qual-8-attempt`** (69 files, outside the repository), with
`evidence-manifest.txt` indexing: 21 Sol run directories, cloud/platform/durable state
snapshots, pre- and post-teardown inventories, the discriminator classification and its 12
probe files. The stopped Phase-0 bundle is `/tmp/sol-gcp-qual-8-phase0-revalidation`
(`/tmp/sol-gcp-qual-8` remains the first, stopped execution's bundle of 2026-09-25).

## New findings and follow-ups

- **`FND-0058`** — a failed platform install leaves a target whose supported destroy cannot
  tear the platform down: reopening the install window is a *create*, which destroy's own
  scope refuses, so the platform teardown is skipped and its state is left stale. Ticket:
  `INFRA-079` (BACKLOG, decision required).
- Harness verdict refinements (non-blocking, for the next attempt): `infirm` classes in
  `INFRA-080` — the `impersonator-binding` probe can never verify absence after a successful
  teardown, the `custom-role` probe should read GCP's `deleted: true` as absent, and
  `cloud_vars`' comment breaks its own continuation (harmless here: the plan argv proves Sol
  passes `-var=provisioner_impersonators=[…]` from the target itself).

## Ledger and findings updates implied

| Row / finding | State after this run |
|---|---|
| `FND-0010` | cause established (`TLS_CA_OR_CERTIFICATE`); reachability hypothesis falsified; **not fixed** — a decision on the fix is a separate unit |
| `INV-AUTH-3` | failure-path window closure **OBSERVED**; the row's own contract still needs the success path |
| `INV-DESTROY-1` | failed-`PlatformInstalling` case exercised, **degraded** (`FND-0058`) |
| `INV-DESTROY-4` | cloud root queried class by class and absent; platform root not destroyed |
| `INV-RET-1` | `retention: none` mechanism OBSERVED live on GCP |
| `INV-EVID-4` | run identity and bundle validated by the harness's own completeness check; no conformant matrix results file was produced (the profile is not conformant) |
| `INV-SUBSTRATE-*`, `INV-IDENT-1` | `NOT REACHED` |
