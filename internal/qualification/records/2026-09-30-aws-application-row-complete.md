# AWS application row: the complete contract on a fresh specimen (2026-09-30)

Specimen `sol-qual-aws-35`, target `qualreg/aws/us-east-1`, account placeholder `123456789012`,
region `us-east-1`. A fresh specimen created after attempt 34's teardown, run with the merged fix
for FND-0075 (`d4d9f48a`) and with **no manual patch at any point**.

## The row

| Boundary | Evidence |
|---|---|
| `cloud plan` | completed against read-only assets |
| `cloud apply` | `CloudBootstrap` → `PlatformInstalling` → `Ready`, `Done.` |
| authority handoff | `de-escalation verified as arn:aws:iam::…:role/sol-qual5-cluster-access` |
| substrate | four nodes Ready; the row's node check passed |
| identity boundary | `identity boundary holds: deploy creates rolebindings, cluster-access does not` |
| build + push | `app-build`, `app-build-worker`, `ecr-login`, `app-push`, `app-push-worker` |
| migrate | `migrate-apply` ok |
| substrate prerequisite | `pluto-payments: no sol-deploy RoleBinding yet`, `pluto-comms: no sol-deploy RoleBinding yet`, then `the deploy established the scoped deploy RBAC in every namespace it entered` |
| deploy | `sol deploy` → "Done. 2 service(s) deployed." |
| transaction | `health: ok`; `charge: {"id":"ch_997038","accepted":true}`; `/notifications` served `ch_997038` back on the first attempt; `read-back: the worker's row is visible to the service` |

The transaction is the contract that matters: a charge was accepted by `charge-svc`, the worker
consumed it from Kafka, wrote it to PostgreSQL, and the service read the resulting row back out.
Nothing was retried into place and nothing was patched.

## What this row exercises

Three defects closed on the way here are all visible in the transcript above:

- **FND-0072** — the substrate step is a prerequisite of the deploy rather than a consequence of a
  profile, and this row shows it on namespaces that had no binding at all.
- **FND-0071** — the platform-lifecycle and application-deploy identities are separate, asserted
  live before any application operation.
- **FND-0075** — the platform derives the range its managed database lives in, publishes it, and
  the deploy grants exactly that range on the database port to the workloads it deploys. On the
  previous specimen the published fact read `10.0.0.0/20,10.0.16.0/20,10.0.32.0/20` with port
  `5432`, the deploy identity could read that one configmap and no other, and the transaction
  passed.

## Boundaries this record does not claim

- **GCP.** Its rendered policies were never enforced — no `network_policy` or datapath
  configuration existed — so its earlier passes did not exercise this contract at all. GCP now
  runs Dataplane V2, and the same contract must be shown on a fresh GCP specimen before GCP can be
  described as qualified for it. Nothing here is evidence about GCP.
- **Endpoint reachability.** The platform reached `Ready` in this row without a cloud load
  balancer and with only NS/SOA published for the base domain. Reachability from outside is a
  separate level from lifecycle readiness and from a certificate being issued, and it stays a
  separate observation until an application that declares an ingress is deployed.
- **FND-0074** (a password interpolated into `POSTGRES_URL` unencoded) remains open and is
  unrelated to this row: this run's password is alphanumeric, and AWS rejects `/`, `@` and `"` in
  `db_password` at validation, which bounds the exposure there but not on GCP.

## Disposition

The specimen was torn down through the supported lifecycle immediately after the row, and its
absence is established by independent inventory rather than by Sol's own report. The durable
`qual-aws.sol-fab.dev` zone is expected to survive and to keep its nameservers.

## Disposition, verified

`sol cloud destroy … --apply` reported *"Done. Destruction reached verified absence."*, and
independent inventory of the account — not Sol's report — shows no EKS cluster, no RDS instance, no
non-default VPC, no elastic IP, no running instance and no ECR repository. The durable
`qual-aws.sol-fab.dev` zone survived with all four nameservers unchanged and still delegating:

```
ns-1335.awsdns-38.org, ns-1560.awsdns-03.co.uk, ns-485.awsdns-60.com, ns-803.awsdns-36.net
```

So the AWS side is back to zero cost-bearing resource, and the only thing that remains is the
prerequisite the next run needs rather than recreates.
