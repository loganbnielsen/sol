# FND-0069 live regression — the corrected destroy converges Attempt 21's standing residue

## Summary

| | |
|---|---|
| revision | `998e20bc` (`FND-0069`: the absence claim comes from the library's verdict, and a cleanup failure no longer immobilises the substrate) |
| specimen | the residue Attempt 21 left standing: `sol-qual-gcp-21` in `ERROR` status, its SQL instance runnable, 200 GiB of SSD quota in use |
| result | **the supported `sol cloud destroy` converged it**: `terraform-destroy ok (276.7s)`, **`teardown verified: absent`**, quota `0/1000`, and Sol's own claim was `Done, with 3 degraded preparation(s). Destruction reached verified absence.` |
| manual action | **none** — the whole exercise is the product's own command |
| new defect found during it | an inconclusive residue probe still allowed the word *verified* (fixed in the same finding, below) |
| unrelated residue seen, not touched | `sol-qual-gcp-15b` (an AR repository, a reserved peering address, a provisioner service account) — from an earlier attempt, not created or left by this run |

## 1. Frozen evidence

| step | evidence |
|---|---|
| provider before | `fnd0069/provider-before.txt`: `sol-qual-gcp-21 ERROR`, `sol-qual-gcp-21-postgres RUNNABLE`, `SSD_TOTAL_GB 200.0/1000.0` |
| Sol's decisions | `fnd0069-destroy` run: `lifecycle phase: PreparingDestroy` → `prepare: disabling the deletion guards…` → `warning: preparation: refused before apply: guard-preparation phase: replace on google_container_cluster.main … is not an action this phase permits` |
| preparation results | three degradations: the guard preparation, the platform teardown (skipped for want of bootstrap authority), and the elevated access — the last now carrying its reason: *"the binding this removes lives inside the cluster, so it is removed with the substrate; destruction continues and the absence check decides whether anything is left"* |
| destruction | `lifecycle phase: Destroying` → `[terraform-destroy] ok (276.7s)` |
| Sol's claimed state | `Done, with 3 degraded preparation(s). Destruction reached verified absence.` |
| independent state after | `fnd0069/provider-after.txt`: no clusters, no SQL instances, `CPUS 0.0/200.0`, `SSD_TOTAL_GB 0.0/1000.0`, the `sol-qual-gcp-21-sql-peering` address gone, the `sol-qual-gcp-21` Artifact Registry repository gone, no `gcp-21` service accounts |
| harness verification | `✓ quota absent` / `teardown verified: absent` — independent of Sol's own verdict |

The decisive difference from Attempt 21 is one line: the run reached **`Destroying`**. Before the fix the same preparation and cleanup failures aborted the command *before* `destroy_substrate`, leaving the cluster permanent while the summary claimed absence.

## 2. What the exercise found, and the fix that followed it

The destroy's verification report contained:

```text
residue check inconclusive -- the GCP residue check could not establish the target's project
(the target declares no gcp.project_id), so the service-networking peering check was not run
(reported, never read as absence)
```

The report was honest — it said the probe did not run — but the *summary* still said **verified**
absence, and `classify` was ignoring the sweep's `indeterminate` list. An observation that did not run
is an unknown, and `is_verified` is defined as "no violations **and** no unknowns"; the intent and the
code had drifted.

Both halves are now closed in the same finding:

- **the summary can no longer claim more than the observation established**: when a residue probe did not
  run, the run reports *"Everything Sol owns is absent and verified, but N residue probe(s) did not run,
  so residue absence is NOT established"* rather than *verified absence*. The verdict's authority is
  unchanged — violations and unknowns decide it exactly as before, which keeps the offline suite's
  "a destroy that reached absence with a degraded preparation must exit 0" contract intact while removing
  the false claim;
- **the probe is made runnable instead of tolerated**: the qualification harness declares
  `gcp.project_id` on its targets (`gcp.project_id` is a key the GCP provider already accepts — checked
  with `sol plan` before the change), so the service-networking peering check actually runs. The suite
  asserts the generated target carries it.

## 3. Ledger

| item | before | after |
|---|---|---|
| `FND-0069` | `OPEN`, high | **`FIXED`** — the false absence claim is gone (`completion_message`), a cleanup failure no longer makes the substrate immortal, and the class has regression coverage; the live regression above is the corrected path converging a real failed cluster |
| Attempt 21's substrate | standing in `ERROR`, 200 GiB in use | **absent**, verified independently |
| `sol-qual-gcp-15b` residue | present | unchanged, reported: an AR repository, a reserved peering address and a provisioner service account from an earlier attempt. Not created by this run and not touched by it; it is the same *family* of question (residue a destroy did not converge), and it predates this fix. Converging it would need its own target/state or a supported path for a target whose run directory is long gone — a decision, not an assumption, so it is reported rather than deleted |
