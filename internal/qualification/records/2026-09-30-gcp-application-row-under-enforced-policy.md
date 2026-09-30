# GCP application row under enforced NetworkPolicy (2026-09-30)

Specimen `sol-qual-gcp-29`, target `qual/gcp/us-central1`, project `sol-qualification`, region
`us-central1`. A fresh specimen run against `main` at `1412db3f`, which carries FND-0075's fix and
the GCP enforcement change. No manual patch was applied to the application path.

## The row

| Boundary | Evidence |
|---|---|
| `cloud plan` / `cloud apply` | `CloudBootstrap` → `PlatformInstalling` → `Ready`, `Done.` |
| delegation | `ns-cloud-c1…c4.googledomains.com` observed for the durable zone |
| kubeconfig | `gke_sol-qualification_us-central1_sol-qual-gcp-29`, pinned while the cluster became RUNNING |
| build + push | `app-build`, `app-push` ok (Artifact Registry) |
| runtime secrets | established from the platform's own output for `POSTGRES_URL`, generated for `SOL_API_KEY` |
| migrate | `migrate-apply` ok |
| deploy | `app-deploy` ok |
| transaction | `health: ok`; `charge: {"id":"ch_209928","accepted":true}`; `/notifications` served `ch_209928`; `the worker consumed the charge and wrote it back` |

## The range correspondence, proven

The platform published, in the cluster fact the deploy reads:

```
{"database-egress-cidrs":"10.94.0.0/16","database-port":"5432"}
```

and the provider independently reports:

```
sol-qual-gcp-29-sql-peering   address 10.94.0.0   prefix 16     (the range Sol created)
sol-qual-gcp-29-postgres      private address 10.94.0.3          (inside that range)
```

So the derived range *is* the private-services-access range, and it contains the address the
instance actually answers on — provider-native derivation, not an author-declared CIDR.

## Reachability comes from the rendered allowance, under enforced policy

The rendered policy in the application namespace:

```
charge-svc-managed-database-egress   selector app=charge-svc
  egress: ipBlock 10.94.0.0/16, port 5432/TCP
```

Single-variable test, run against the deployed service over a port-forward:

1. **Allowance removed** — `GET /health` still answered `ok`, but
   `POST /charges` returned nothing for 45 s (`http 000 after 45.002111s`): the workload could not
   reach Cloud SQL.
2. **Allowance restored** — the same request answered
   `{"id":"ch_392804","accepted":true}` in **0.16 s**.

That is the point the AWS run could not make on its own: on GCP the database is reachable *because
of* the rendered allowance, not because networking happens to work. The pool, the credentials and
the DNS are unchanged between the two measurements; only the policy differs.

Note on the enforcement flag: the cluster API reports the network-policy addon present
(`addonsConfig.networkPolicyConfig`) — the behavioural measurement above is the evidence that
matters, and the cluster was created by this revision's `datapath_provider = "ADVANCED_DATAPATH"`.

## Defects this row found

**In the product — the destroy cannot drop a database that deployed workloads are still using.**
The first supported destroy converged on everything except:

```
Error: Error when reading or editing Database: googleapi: Error 400: Invalid request: failed to
delete database app. Detail: pq: database "app" is being used by other users., invalid
```

The GKE cluster and the workloads were destroyed *before* the database in the same run, but the
database deletion was attempted while the application's pooled connections were still open. The
lifecycle needs to stop the workloads Sol deployed — or wait for their connections to close —
before it asks the provider to drop the database. The specimen was then destroyed by re-running the
supported destroy once the cluster (and with it the connections) was gone; nothing was deleted at
the provider by hand.

**In the product — two absence probes could never run.** With everything destroyed, the run
reported *"Everything Sol owns is absent and verified, but 2 residue probe(s) did not run, so
residue absence is NOT established"*: Sol's GCP inventory called
`gcloud compute networks subnets list --region` and `gcloud compute routers list --region`, and
gcloud accepts `--regions`. Fail-closed worked exactly as intended — the absence claim was
withheld — and the probes are now fixed, after which the same destroy reported *"Done. Destruction
reached verified absence."* with no degraded probe.

**In the qualification harness — two teardown defects.** The destroy phase requires `CLUSTER` but
uses `IMPERSONATOR`, which it does not require (`IMPERSONATOR: unbound variable`); and the app
phase rewrites the target file with the *application* target, after which the destroy phase
refuses that file ("was not written by this harness"), finds no target declared and exits without
destroying — leaving a live specimen and an empty target file behind. Both mean the harness cannot
tear down its own specimen without repair, which is how this row's teardown had to be driven.

## Disposition, verified

`cloud destroy` reported *"Done. Destruction reached verified absence."* Independent inventory —
provider reads only — shows zero clusters, SQL instances, VM instances, disks, routers, addresses
and artifact repositories; the only network present is GCP's own `default` with its default
firewall rules. The durable `qual-gcp.sol-fab-dev` zone survives with all four nameservers
unchanged and still delegating, so no re-delegation is needed.

Both providers are therefore back to zero cost-bearing resource, each keeping only the durable
delegated zone its next run reuses.
