# AWS qualification Run 5, attempt 2 — 2026-09-19

> Moved verbatim on 2026-09-24 from `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md` (lines 629–679 at `a9d7d827`), when the HARDEN-002 epic was closed as a ticket and its run history moved into the qualification ledger. Headings keep their original levels; the text is unchanged. Index: `docs/qualification/README.md`.

## Run 5 attempt 2 (executed 2026-09-19) — NON-CONFORMANT: finding 19 blocking

Fresh disposable target `sol-qual6-9dda701e` (same target path, 111122223333 / us-east-1),
run after INFRA-030's capacity contract was on `main`.

| Stage | Result |
|---|---|
| `sol cloud plan` | clean; profile-derived shape enforced (`node_instance_types=["m6i.xlarge"]`, `node_desired_size=4`, `node_min_size=3`, `node_max_size=10`) |
| `terraform-apply` (cloud) | **ok**, 880.4s |
| `platform-prerequisites-apply` | ok, 48.9s |
| `platform-apply` | **FAILED**, 166.4s — `helm_release.alloy` |

**finding 19 — the alloy chart cannot be downloaded (INFRA-032).**
`helm_release.redpanda` and `helm_release.loki[0]` both reached `Creation complete`,
and every other platform component was observed `Running`, while alloy failed with
`could not download chart: Chart.yaml file is missing`. Alloy was the only chart in
the platform root still sourced from the legacy `grafana.github.io` repository; that
index advertises archives on GitHub releases rather than at the
`<repo>/<chart>-<version>.tgz` path the Terraform helm provider resolves. Attempt 1
had treated this as transient; attempt 2 reproduced it on a fresh target, so that
position is discharged. Fixed by INFRA-032 (the chart is named by archive URL).

### finding 16 verification — the capacity fix works (live)

Planned shape came from the profile, appended last so a target field or `--var`
cannot weaken it, and the platform's own components scheduled:

- live nodes: **4 × m6i.xlarge** (16 vCPU), versus attempt 1's 3 × m6i.large (6 vCPU);
- `redpanda-0/1/2`: **2/2 Running** (attempt 1: `0/3 nodes are available: 3 Insufficient cpu`);
- `loki-0`, `loki-chunks-cache-0`, `loki-results-cache-0`: **2/2 Running** (attempt 1: Pending);
- grafana, prometheus, alertmanager, kube-state-metrics, loki canaries: all Running.

### INFRA-033 found while tearing this attempt down

The first `sol cloud destroy` **crashed mid-teardown** with an uncaught
`Sys_error(.../runs/cloud-destroy-20260919T001717Z-23151/platform-destroy.log: No such
file or directory)` — its run directory had been pruned underneath it, leaving the
cluster, four nodes and Multi-AZ RDS provisioned and billing until the destroy was
re-run (which completed normally: `terraform-destroy` ok, 713.9s). Root cause:
`run_log.create` prunes to the newest 20 run directories and excluded only the run
being created, so any new `sol` invocation could delete a live run's directory. Fixed
by INFRA-033.

### Cost-clean verification

EKS `list-clusters` empty and `describe-cluster` `ResourceNotFound`; RDS 0 instances;
4 instances `terminated`; NAT gateway `deleted`; EIP 0; ELBv2 0; EBS volumes 0;
non-default VPCs 0; ECR repos 0. The disposable final snapshot was recorded and then
deleted (qualification-account hygiene; Sol's production destroy behaviour is
unchanged).
