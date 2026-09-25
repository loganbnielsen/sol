# GCP Attempt 5 — 2026-09-22

**Outcome:** stopped deliberately, not by a defect in the substrate. The cloud root
applied cleanly; the attempt then found a **lifecycle defect** (`FND-0029` /
`INFRA-067`) and was halted by the operator before the platform stage. Everything
billable was torn down, and the postcondition was verified independently through the
provider's API. Attempt 6 is gated on the destroy invariant and on deliberate zone
ownership.

## Run identity

| | |
|---|---|
| Target | `qual/gcp/us-central1` (untracked scratch, per the account-artifact guard) |
| Revision | `main @ 1ebb186f` (harness `#440`) |
| Project / region | `sol-qualification` / `us-central1` |
| Cluster | `sol-qual-gcp-5` |
| Base domain | `qual-gcp.sol-fab.dev` (`DEC-042`) |
| Harness | `internal/qualification/gcp/live-qual.sh`, phases `cloud` then `platform` |

## Chronology

| Time (local) | Event |
|---|---|
| 15:47:41 | `bootstrap`: state bucket `gs://sol-qualification-tfstate` **already present**, left untouched (idempotent ensure) |
| 15:47:41 | `cloud`: target written; `terraform-init` against the GCS backend, `prefix=sol/qual/gcp/us-central1/cloud.tfstate` |
| 15:47–15:57 | `CloudBootstrap`: `terraform-apply ok (592.2s)` — 17 managed resources: GKE, Cloud SQL, VPC/subnetwork, router+NAT, address, peering, Artifact Registry, provisioner SA + IAM |
| ~15:50 | Cloud DNS zone `qual-gcp-sol-fab-dev` created by the cloud root (`create_dns_zone = true`); four `ns-cloud-c*` nameservers read directly from the zone |
| 15:57 | `provisioner-bootstrap-access-remove ok (9.1s)` — install window closed |
| 15:57:48 | **Refused**: the target declares `cluster_issuer`, and Sol cannot yet wire a GCP issuer (Route 53-only solvers). See `FND-0029`. |
| 16:0x | First teardown attempt: `sol cloud destroy --apply` failed because the harness's `cleanup` had already deleted the target file, which destroy requires |
| 16:1x | Second attempt: `terraform state rm` of the zone (to protect it) then destroy — refused with `409 alreadyExists`, because the `PreparingDestroy` reconciliation apply wanted to recreate the zone it no longer tracked |
| 16:2x | Third attempt (detached): progressed — Cloud SQL deleted, address released, GKE began `STOPPING` — then the process was **SIGKILLed** when a monitoring call was interrupted, leaving a stale state lock |
| ~16:40 | Lock cleared with `terraform force-unlock` after confirming no Terraform process remained (normal recovery, not a defect) |
| ~16:45 | Destroy with `create_dns_zone=false` and `cluster_issuer` removed from the target: **Done.** |

## Independent postcondition (provider API, not Sol's exit code)

| Must be absent | Result |
|---|---|
| GKE cluster | absent |
| Cloud SQL instance | absent |
| Target VPC + subnetworks | absent (only the project's `default` remains) |
| Router + NAT | absent |
| Addresses / disks / forwarding rules | absent |
| Service-networking peering | absent |
| Target service accounts | absent |
| Quota usage (`CPUS`, `IN_USE_ADDRESSES`, `SSD_TOTAL_GB`, `DISKS_TOTAL_GB`, `INSTANCES`) | all `0` |

The independent check is the reason this attempt did not end with a false
"destroy succeeded": the first teardown attempt *reported* failure, but the check is
what proved resources were still live and drove the recovery.

## Delegation (`DEC-042`)

The delegation **is live and correct**, verified over DNS-over-HTTPS:

```
qual-gcp.sol-fab.dev NS -> ns-cloud-c1..c4.googledomains.com
(parent) sol-fab.dev NS  -> nsd1-4.squarespacedns.com
```

Plain `dig` on port 53 returns nothing from this environment — outbound DNS is blocked
here — so the harness's `dig`-based delegation wait is unreliable and must use DoH.

## Residue (deliberately unresolved)

| Object | Condition |
|---|---|
| Cloud DNS zone `qual-gcp-sol-fab-dev` | **present** and delegated; **not in Terraform state** (removed to protect it from a destroy that cannot distinguish durable prerequisites) |
| GCS state bucket `gs://sol-qualification-tfstate` | present (durable prerequisite) |
| State objects | `sol/qual/gcp/us-central1/{cloud,platform}.tfstate` |

This is **incident residue, not the intended implementation of `DEC-042`**. A zone that
exists, is delegated, and is unmanaged is stable enough to leave alone while ownership
is decided, but it must not become the baseline for Attempt 6: before another live
attempt, the zone needs a deliberate Terraform owner — most plausibly whichever state
`DEC-043` decides should own durable prerequisites. Re-importing it is a decision, not
cleanup.

## What this attempt does not establish

- Anything about the platform stage or `FND-0010`: the platform install never ran.
- Whether the profile requires the alert quartet or a registry on GCP.
- Whether AWS is affected by the same lifecycle asymmetry (the check lives in the
  shared platform definition, so the mechanism is provider-neutral).

## Correction (2026-09-24, DOCS-022)

The "second attempt" row records a `terraform state rm` of the zone followed by a `409
alreadyExists` from the `PreparingDestroy` reconciliation apply. That provider-present /
state-absent zone was **created by the operator's state surgery**, not by Sol's lifecycle. The
defect it exposed was real: a whole-root reconciliation apply on the destroy path would recreate
anything configured but missing. It was fixed by plan-and-assert (HARDEN-004 part 3), and DEC-045
keeps that invariant. The "third attempt" row's SIGKILL came from an interrupted monitoring call in
the agent's session, not from Sol. The stale lock and the later force-unlock follow from that
kill. Operating rules now forbid pattern kills and unlocking a live lock (`docs/qualification/README.md`).
