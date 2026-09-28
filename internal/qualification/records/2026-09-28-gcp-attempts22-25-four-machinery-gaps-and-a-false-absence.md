# GCP application row — attempts 22–25: four machinery gaps closed, and a false absence found

## Summary

| attempt | revision | how far it got | what it established |
|---|---|---|---|
| 22 | `d8b8ee7f` | substrate → `Ready` (certificate gate) → build → push → **stop at `sol migrate apply`** | the strengthened `Ready` contract holds on a fresh target; `POSTGRES_URL` must come from the cluster root's `postgres_url` output (the documented operator step) |
| 23 | `ff8352c1` | **stopped at the substrate** — `Google Compute Engine does not have enough resources available to fulfill request: us-central1` | the region itself was out of capacity for the profile's node shape |
| 24 | `a30d54d4` | substrate → `Ready` → build → push → secrets → **stop at `sol migrate apply`** | the workspace's declared runtime secrets are exactly `POSTGRES_URL` + `SOL_API_KEY`; and the migration Job needs the target's registry |
| 25 | `a30d54d4` | substrate → **stop in the substrate**: `Error waiting for Create Instance` on `google_sql_database_instance.postgres` | **FND-0070** — see below |

Attempts 22 and 24 each produced a small, real harness gap, fixed and merged in the same loop
(`#678` the runtime secrets, `#679` the migration Job's registry). Attempt 23 was the provider refusing to
place the cluster at all. None of the four was blocked by a product defect — the product behaved correctly
at every point it was reached, including refusing to proceed without the secrets its own contract requires.

## Status of the row's objectives

| objective step | state |
|---|---|
| supported substrate | **observed** (attempts 22, 24, 25 — 25 only the cluster) |
| platform `Ready` under the strengthened contract | **observed** twice (22, 24) |
| build + push to the target registry | **observed** twice (22, 24) |
| `sol migrate apply` | **not yet observed** — needs `--registry` (fixed) and now has it |
| `sol deploy` | **not yet observed** |
| the transaction (charge → worker consumes → worker writes → service reads back) | **not yet observed** |
| supported teardown → independently verified absence | **observed** (24: `teardown verified: absent`) |

## FND-0070 — the finding that attempt 25 produced

Attempt 25's apply failed with `Error waiting for Create Instance` on the SQL instance, **but the provider
created it anyway**, so it was never recorded in Terraform's state. The supported destroy then did
everything its state allowed, and reported:

```text
    residue Terraform does not own (controller load balancers, PVC volumes, abandoned peering): none found
Done. Destruction reached verified absence.
```

while the provider holds `sol-qual-gcp-25-postgres RUNNABLE` and the harness's independent check says
`verify: resources remain`. The mechanism, the GCP sweep's thinness compared with the AWS sweep, the
recurrence this likely explains (`sol-qual-gcp-15b`), and the three reclamation options needing a decision
are all in `internal/pipeline/audits/findings/FND-0070-….md`.

**`sol-qual-gcp-25-postgres` is left standing deliberately.** It cannot be reached by the supported destroy
path — that is the finding — and deleting it by hand would hide it, so it waits for the decision.

## The harness verdict was corrected in the same pass

Attempt 22 and 23 had been flagged for the region's `SSD_TOTAL_GB` reading with no owning resource listed,
and I first recorded that as "quota accounting lagging". Attempt 25 shows the reading was pointing at
something real the whole time: an unlisted consumer. The verdict is now **three-valued** — `ABSENT` (all
zero), `PRESENT` (an authoritative list accounts for the usage), `UNKNOWN` (non-zero with no identified
owner, *never* read as absence) — and `UNKNOWN` does not pass a teardown verification. That is the strict
reading of the same rule the destroy path follows, and it means a false alarm is preferred to a false clean
verdict.
