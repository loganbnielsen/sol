# Cloud inventory code audit — 2026-09-29

Audited freshly synchronized canonical `main` at `3f662e7b5e2262d958b1b7b023b76bb07036970a`. Filed BUG-084..086. These are source and local CLI-parser findings; no provider account was queried and no implementation was changed.

## Scope and reconciliation

Read the roadmap, work summary, audit guidance, earlier code-quality reports, the current ticket corpus and open PRs. BUG-083 is already filed on main. REFAC-156/158 are under PR #721 and AWS qualification is under PR #719; neither owns the three inventory contracts here. Traced `Sol_cli_aws_absence`, `Sol_cli_gcp_absence`, `Sol_cli_absence`, `Sol_cli_ownership_reconciliation`, `Sol_cli_cloud_wiring`, explicit reconcile and destroy controllers, and representative recovery tests. The scan also sampled service authentication/lifecycle and subprocess behavior; those paths did not produce an additional verified finding.

## BUG-084 — AWS load-balancer command cannot run

`cli/lib/cloud/sol_cli_aws_absence.ml` builds `aws elbv2 describe-load-balancers --filters Name=tag:kubernetes.io/cluster/<name>,Values=owned,shared`. The installed AWS CLI's input skeleton lists `LoadBalancerArns`, `Names`, `Marker`, and `PageSize`, with no `Filters`. Direct parser probe:

```text
$ aws elbv2 describe-load-balancers --region us-east-1 --filters Name=tag:demo,Values=owned,shared --no-sign-request
aws: [ERROR]: Unknown options: --filters, Name=tag:demo,Values=owned,shared
```

The parser rejects the command before a network request. A normal supported command's skeleton is the positive control. `run` converts the failure to `Unobservable`; `Sol_cli_absence.to_sweep` carries that as indeterminate, so verified absence is unavailable while this check remains broken. The ticket asks for a supported tag-aware inventory path and a command-level regression.

## BUG-085 — unknown checks disappear from reconciliation

`Sol_cli_ownership_reconciliation.dispositions` maps only `Present` to dispositions; `Unobservable` is dropped along with `Absent` and `External`. When every provider check fails, `outcome []` emits `Infrastructure ownership is reconciled. No changes.` The explicit command in `cli/bin/cmd_cloud_tf.ml` computes `outstanding` only from dispositions and returns `Ok ()` for an empty list. The positive control is `Sol_cli_absence.verdict`, which correctly returns `Some_unknown` for the same `Unobservable` variant. Reconciliation must preserve this information too. This is source traced; no provider failure was induced against a live target.

## BUG-086 — GCP location omitted from two commands

`Sol_cli_gcp_absence.checks ~project ~region ~cluster_name` includes target region for Artifact Registry but omits it from the location-scoped node-pool and Cloud NAT invocations. Local parser probes, with no active account needed:

```text
$ gcloud container node-pools list --cluster=probe --project=probe --quiet --format='value(name)'
ERROR: (gcloud.container.node-pools.list) One of [--location, --zone, --region] must be supplied.
$ gcloud compute routers nats list --router=probe --project=probe --quiet --format='value(name)'
ERROR: (gcloud.compute.routers.nats.list) Underspecified resource [probe]. Specify the [--router-region] flag.
```

The command help lists the respective location flags, which is the positive control. User-level `gcloud` defaults can mask this in a developer session or select a different region; the resolved target is the command's authority. The ticket covers both checks as one location propagation defect.

## Candidates retained

- `Sol_cli_ownership_reconciliation.matches` uses substring matching. The provider adapters first filter observations by target identity, and this pass did not establish a realistic wrong import from the substring alone.
- `Sol_cli_process.run` briefly changes process-wide cwd for commands using `~cwd`, but the inspected production callers do not use that option in concurrent CLI operations; the existing workspace cwd question is already BACKLOG/REFAC-110.
- Service JWKS validation and shutdown have dedicated tests for temporal claims, cache refresh, and stop timing. No independent high-priority defect was established from the paths read.

The recommended path is `provider command with explicit target context -> complete typed observations -> readable Terraform state -> reconciliation outcome -> optional import`. Failure at either observation or state reading cannot become a success claim.
