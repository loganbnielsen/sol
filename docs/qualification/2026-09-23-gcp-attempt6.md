# GCP Attempt 6 — 2026-09-23

**Outcome:** aborted before the platform stage by a harness defect, then recovered to a
clean provider inventory entirely by hand. It did **not** reach FND-0010. Its value is the
second, stronger destruction defect it exposed (`FND-0030`).

**Cost exposure at close: zero**, verified two-sided; the durable prerequisites are intact
and the delegation still resolves.

## Run identity

| | |
|---|---|
| Cluster | `sol-qual-gcp-6` |
| Revision | `main @ 835841a8`, with the Attempt-6 branch (`HARDEN-004/attempt-6`) adding the target fix |
| Binary | `sol --version` = `835841a8` — asserted equal to worktree HEAD before launch |
| Delegation | already live (`qual-gcp.sol-fab.dev NS → ns-cloud-c1..c4`), so no human step was needed |

## Chronology

| Time | Event |
|---|---|
| 13:01 | `PLAN_ONLY` green; `cloud` launched detached. Durable root reconciled: "already matches its declared state" |
| 13:01 | The early hand-off fired immediately (the zone already exists) |
| 13:02 | `cloud-apply` starts; GKE `PROVISIONING`, Cloud SQL `PENDING_CREATE` |
| 13:11 | **Aborted by the operator.** The terraform command line showed `-var=create_dns_zone=true`, overriding the var-file's `false` (DEC-043 moved the zone to the durable root) — the apply would have failed on the existing zone after ~10 minutes |
| 13:11–13:12 | Kill by pattern matched the operator's own shell (twice), and killing the harness **orphaned its `terraform apply`** |
| 13:12 | The harness's own teardown ran `sol cloud destroy` with **no variables**: `destroy_vars` had been deleted by the `reconcile_durable_root` refactor |
| 13:13–13:20 | `sol cloud destroy --apply` fails: state lock from the killed apply; then, after clearing it, `gcp-destroy-prepare` fails with `409 Already exists` on the cluster (present in the provider, absent from state) — see `FND-0030` |
| 13:20–13:45 | Recovery: `terraform import` of the cluster (hung on a `PROVISIONING` cluster), then direct deletions — Cloud SQL (deletion protection patched off first) — then the cluster via a retry loop until the orphaned GKE operation cleared, then `terraform state rm` of three stale SQL entries, then `terraform destroy` of the remaining 11 resources |
| 13:45–14:05 | Independent verification: target absent, durable present (below) |

## Postcondition (provider API, not Sol's report)

| Must be absent | Result |
|---|---|
| GKE cluster, Cloud SQL | absent |
| Target network / subnets / router + NAT / addresses / peerings | absent (only the project's `default` network remains) |
| Target service accounts | absent |
| Quota usage (`CPUS`, `IN_USE_ADDRESSES`, `SSD_TOTAL_GB`, `DISKS_TOTAL_GB`, `INSTANCES`) | all `0` |

| Must be present | Result |
|---|---|
| Cloud DNS zone `qual-gcp-sol-fab-dev` (durable, DEC-043) | present |
| GCS state bucket `sol-qualification-tfstate` | present |
| Registrar delegation | live — 4 NS records |

## What this attempt establishes

- `FND-0030`: destroy is unavailable for a partially represented target because
  `PreparingDestroy` reconciles constructively before destroying.
- The harness is now part of the qualification system and needs its own qualification: a
  refactor silently deleted `destroy_vars`, leaving the teardown path passing no variables
  at all — dead in merged code, found only by running it.
- Two settings for one value (`create_dns_zone` in the var-file and as a CLI override) let
  each source look correct while the override won.
- Pattern-matching a process to kill is the wrong primitive: it matched the operator's own
  shell, and killing a wrapper orphans its `terraform apply`, which then produced the
  state/provider divergence this attempt is remembered for.

## What it does not establish

- Anything about cert-manager or `FND-0010`: the platform stage never ran. The
  discriminator remains unobserved.
- Whether the recovery requirement can be met by a phase-boundary change or needs an
  explicit recovery operation.

## Evidence

Raw logs (containing project identifiers, hence kept outside the repository) were frozen to
`~/sol-attempt6-evidence/`; the chronology above is the readable extraction.
