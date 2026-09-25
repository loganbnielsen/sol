# GCP Attempt 8 — Phase 0 stop (2026-09-25), pre-live, no mutation

> **Status.** Attempt 8 was authorized and began. Its **read-only Phase 0** stopped the run before
> any provider mutation. The authorized live-infrastructure attempt is **not consumed** by this
> execution: nothing was created, nothing was destroyed, no Terraform state was touched.
>
> **This record is kept, not replaced.** The continuation after the corrective work references this
> stop explicitly; it is the causal head of the Attempt 8 chain.

## Result

| Field | Value |
|---|---|
| Revision executed | `1aad2623` (worktree `../sol-attempt8`, branch `HARDEN-006/attempt-8`; `sol --version` = `1aad2623`, asserted equal to HEAD) |
| Result | **`STOPPED_PHASE_0`** |
| Reason | provider inventory `UNKNOWN` — one of the authorization's stop conditions |
| Provider mutation | **none** |
| Billable resources created | **none** |
| `FND-0010` | **`NOT_REACHED`** (no install attempted) |
| Phases entered | Phase 0 only; Phases 1–4 not entered; no target file written |
| Live/elapsed time | 21:29:24Z → 21:30:10Z (≈46 s, all read-only provider reads) |
| Operator values used | `IMPERSONATOR=user:lbendtlynielsen@gmail.com`, `LE_EMAIL=qualification@sol-harden-qualification.dev` (the address recorded as verified live against the ACME server — `docs/qualification/2026-09-19-aws-run5-attempt3.md`) |
| Evidence bundle | `/tmp/sol-gcp-qual-8/` (outside the repository; provider identifiers) |

## What Phase 0 observed

Identity `lbendtlynielsen@gmail.com` (`roles/owner` on the project); project `sol-qualification`
`ACTIVE`; billing enabled. Then `internal/qualification/gcp/live-qual.sh verify` — read-only provider
reads, no mutation:

| Class | Verdict |
|---|---|
| gke-cluster, sql-instance, network, subnetwork, router, nat, address-regional, address-global, disks, forwarding-rules, artifact-registry, custom-role, role-binding, peering | **ABSENT** |
| service-account-provisioner, service-account-loki, service-account-thanos, impersonator-binding | **UNKNOWN** ← the stop |
| state-bucket, dns-zone (durable prerequisites) | **PRESENT** |
| quota (CPUS / IN_ADDRESSES / disk / instances) | **ABSENT — usage 0** |

Independently re-checked after the stop, read-only: no GKE cluster, no Cloud SQL instance, no address
(regional or global), no disk, no non-default service account; delegation for
`qual-gcp.sol-fab-dev` still resolving over DoH (`ns-cloud-c1..c4`). Nothing was created.

## Why it stopped — two harness defects, not a provider or product defect

**A. `provider_probe` does not recognise the provider's own not-found vocabulary.** Captured verbatim
in the bundle (`inventory-service-account-provisioner.stderr`):

```
ERROR: (gcloud.iam.service-accounts.describe) NOT_FOUND: Unknown service account. This command is
authenticated as lbendtlynielsen@gmail.com which is the active account specified by the
[core/account] property
```

The probe accepts `(not[ -]?found|does not exist|was not found|notFound|404|No URLs matched)`, and
`NOT_FOUND` carries an **underscore** that `[ -]?` does not cover. Fail-closed (never a false ABSENT),
but it would have stopped every attempt in Phase 0. Reproduced deterministically: the pattern does not
match the captured text; adding `_` to the character class does.

**B. `verify` escalates to a teardown when verification fails.** `verify` sets `KEEP=1` *after* its
failure branch exits, so the EXIT trap's "a failed run is presumed to have created something" rule
called `destroy` — the bundle's `destroy.log` holds that invocation. It mutated nothing only because
no target file existed (the CLI refused before touching the provider); with one present it would have
torn down the target the operator asked merely to inspect.

Both are filed as **`INFRA-078`** with their evidence, and fixed by the corrective PR recorded in the
continuation's run record.

## What this execution does not establish

- Nothing about `FND-0010`: `sol cloud apply` was never invoked, so the cert-manager boundary was not
  reached and the reachability hypothesis is neither supported nor contradicted.
- Nothing about the GCP lifecycle, `Ready`, retention, or any matrix row. No row is advanced by this
  record.
- It is **not** a failed attempt at the run's purpose; it is a pre-live gate that fired correctly on a
  harness defect. A gate that stops before spending, with the defect named and reproducible, is the
  gate working.
