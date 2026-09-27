# GCP qualification Attempt 13 (2026-09-26) — stopped by a defect in the INFRA-090 change

## Summary

| | |
|---|---|
| revision | `d44c85d6` (main, post-merge CI green) |
| target | `qual13/gcp/us-central1`, cluster `sol-qual-gcp-13`, project `sol-qualification` |
| result | **`STOPPED`** — a fail-closed refusal from the newly landed disk-quota check |
| provider mutation | substrate created, then destroyed by the supported path; **no residue** |
| billable resources created | the cluster and its nodes for ~10 minutes; no volumes ever bound |
| FND-0010 | **NOT REACHED** (the platform install never started) |
| FND-0062 / INFRA-090 | **not qualified**: the new check refused before its first observation |

## What happened, with timestamps (UTC)

| time | event |
|---|---|
| 00:44:47 | run launched; preflight green, including `disk-quota: PRESENT (SSD_TOTAL_GB limit=1000 usage=0 free=1000)` |
| 00:52:07 | cloud root applied; the run stops with `error: the cloud root published no project_id` |
| 00:52:51 | pre-teardown inventory frozen (all disposable classes PRESENT as expected for a live cluster) |
| 00:52:56 | evidence frozen: Terraform state (cloud, durable captured; platform not initialised), Sol run record, discriminator capture |
| 00:54:07 | supported destruction complete |

Nothing was installed and nothing needed to be: the refusal came from the new check, which runs
after `cloud_ready` and before `with_cluster_access`. The fail-closed direction was correct — it
refused rather than comparing against an unknown project — but it refused for a reason of its own
making.

## The defect, and how it was proved

`Sol_cli_gcp_cluster.project_id_of_outputs_json` expected `terraform output -json` to wrap the
value as either a bare string or `{"value": "..."}`. Terraform emits three fields:

```console
$ terraform output -json          # reproduced offline, /tmp/tfshape
{ "project_id": { "sensitive": false, "type": "string", "value": "sol-qualification" } }
```

The parser's inner-object case required exactly one field named `value`, so the real shape matched
nothing and the project was reported missing. The shape is reproduced above rather than summarised:
a trivial root with one string output and no providers is enough.

## Why the offline suites did not catch it

They encoded the same wrong assumption as the code. `cli/test/test_disk_quota.ml` fed the *bare*
shape, and `internal/ci/test_cloud_lifecycle_offline.sh`'s `terraform` stub printed the bare shape
too, so both agreed with the parser and with each other while disagreeing with Terraform. This is
the class of error the repository's rules warn about — a green test that shares the implementation's
assumption is not evidence about the world.

## Safety and evidence

- Supported destruction ran; the post-state is independently verified: **no clusters, no disks**,
  `SSD_TOTAL_GB 0.0/1000.0`, durable prerequisites untouched.
- The bundle is frozen before teardown as designed: state snapshots, Sol run record, pre-teardown
  inventory, discriminator capture, phase transcripts (`/tmp/sol-gcp-qual-20260926-184447`).
- The harness reports the bundle as **INCOMPLETE** because `state/platform.tfstate` is missing —
  correct file, wrong rule: the platform root was never initialised, because the run stopped before
  the platform. The completeness rule should accept a platform state that never existed when the run
  stopped pre-platform, and that is part of the follow-up.
- The FND-0010 classification recorded `UNKNOWN`, which is the honest answer: cert-manager was never
  reached, and the capture had no failure to classify.

## What this changes for the next run

The fix is small and its shape is already known: read `value` out of the output wrapper rather than
requiring it to be the only field, with the *captured* payload above as the test fixture and the
offline harness's `terraform` stub corrected to emit the real wrapper. Until that lands, any GCP run
from this revision stops at the same place.
