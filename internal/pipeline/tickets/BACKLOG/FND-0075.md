---
id: FND-0075
type: audit-finding
severity: high
source: AWS attempt 33 (discovery specimen) — the charge request hangs on a cluster that enforces NetworkPolicy
---

**Depends on:** None.

**Related:** FND-0073 (the same hang, traced to here), `cli/lib/workspace/sol_cli_manifest_yaml.ml`
(`network_policy_doc`, `platform_egress`), `internal/qualification/records/2026-09-30-aws-attempt33-the-application-contract-passes-except-network-policy-egress.md`.

# The rendered NetworkPolicy grants no egress to a managed database

## What happens

A service whose database is a managed instance — the case both qualification targets declare with
`resources: { app_db: … }` — receives a NetworkPolicy that allows egress to DNS, to the
`redpanda`, `postgresql` and `monitoring` namespaces, and to its declared peers. There is no rule
for the database's own address, because the managed endpoint is not in any namespace. On a cluster
that enforces the policy, the service's connection to its database is dropped, and since the drop
is silent the request does not fail — it hangs.

## Evidence, all live on AWS attempt 33

**The request hangs with no database session at all.** During a hanging `POST /charges`, an
in-namespace psql Job saw only its own session in `pg_stat_activity` (`datname = 'app'`), no
ungranted locks, no blocking pids — and then ran the service's own statement successfully:

```
== direct insert of the service's own statement shape ==
INSERT 0 1
```

So the block is before the query is sent.

**The same image with the same environment works.** Running the *deployed service's own image*
with the *same* configmap and secret as a bare Job — no NetworkPolicy selects it — answered
`{"id":"ch_156941","accepted":true}` in 52 ms, on the hostname URL and on an IP-substituted URL
alike. Code, pool, DNS, credentials and URL are therefore all fine; the difference is the deployed
pod's environment, and the only thing that distinguishes it is the rendered policy.

**The policy has no managed-database rule.** `charge-svc-netpol` egress, verbatim:

```
- ports: 53/UDP, 53/TCP
- to: namespace redpanda, namespace postgresql, namespace monitoring
- to: namespace pluto-checkout, pod app=checkout-svc
```

**Closing it fixes it, in one variable.** Adding an egress rule to the cluster's VPC range on
5432 made the deployed service answer `202` in 1.09 s; adding the same to the worker's policy made
the complete contract pass — charge accepted, consumed from Kafka, written to PostgreSQL, and
served back by `GET /notifications`. Both experimental patches were then removed, leaving the
specimen exactly as Sol rendered it.

## Why GCP passed and AWS did not

The GCP row ran the identical contract against a managed Cloud SQL instance and completed. The
policies Sol renders are provider-neutral, so the difference is enforcement: the drop here is
proven (the same pod works once the rule exists), while the GCP cluster did not enforce its
rendered policy — GKE Standard enables NetworkPolicy enforcement only when the cluster asks for
it. That side is an inference from provider defaults, not something measured in this attempt, and
it should be confirmed before it is quoted as fact. What the AWS evidence establishes on its own
is that the rendered policy does not describe the managed database, and that this is the only
thing that broke the contract.

## The decision this needs

Where the managed database's range comes from is a product-contract choice with materially
different postures, and the existing boundaries do not determine it:

1. **Derive it from the target's own cloud state** — Sol provisions the VPC and the database's
   subnets (AWS) and the private-services range (GCP), so it can emit an egress rule for the range
   it placed the database in, on the database port. No new author-facing contract, and the range
   is Sol's own private range rather than the internet. Requires new provider outputs and a way
   for the deploy's manifest rendering to see them.
2. **Let the workspace or target declare its external egress** — explicit operator policy, most
   flexible, but it adds a field to the author-facing contract and puts the burden of knowing the
   range on the author.
3. **Allow the database port to any address** — smallest change, widest reach; not recommended,
   because it grants every workload the right to open database connections anywhere.

The recommendation is (1): the resource is already declared in the target, Sol already creates and
owns the range, and nothing new is asked of an application author. It is deliberately not
implemented here, because which reachability the platform grants by default is a security posture
the operator owns — the same rule that kept FND-0071's fix from widening a group.

## Acceptance criteria

- A service that declares a managed database can reach it on a cluster that enforces
  NetworkPolicy, verified on EKS by the full application transaction.
- The egress granted is bounded to the range Sol provisioned the database in, on the database
  port — not the internet.
- The provider-neutral manifest keeps one shape, with the range supplied per provider where their
  private connectivity differs.
- Coverage: a rendered manifest for a target that declares a managed database contains the
  database egress rule, and one for a target that does not, does not — mutation-tested, so the
  rule cannot silently disappear again.
- The GCP enforcement question above is settled, so the two providers' postures are known rather
  than assumed.
