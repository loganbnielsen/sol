# AWS attempt 33: the whole application contract passes — except the network policy's egress

Discovery specimen `sol-qual-aws-33`, target `qualreg/aws/us-east-1`. A fresh specimen after
attempt 32's teardown; the durable `qual-aws.sol-fab.dev` zone was reused unchanged (its four
nameservers still delegate).

## The cloud and application boundaries

```
bootstrap: state bucket present; durable root already matches its declared state
lifecycle phase: CloudBootstrap → PlatformInstalling
de-escalation verified as arn:aws:iam::…:role/sol-qual5-cluster-access
lifecycle phase: Ready
Done.
```

The app phase then reproduced attempt 32 exactly, including the FND-0072 substrate behaviour:

```
identity boundary holds: deploy creates rolebindings, cluster-access does not
pluto-payments: no sol-deploy RoleBinding yet
pluto-comms:     no sol-deploy RoleBinding yet
app-deploy → the deploy established the scoped deploy RBAC in every namespace it entered
```

and the transaction failed at its first request, as before.

## The trace

**The service never opens a database connection.** During a hanging `POST /charges`, a psql Job in
the same namespace saw only its own session in `pg_stat_activity WHERE datname = 'app'`; no
ungranted locks; no blocking pids; and it then ran the service's exact statement —
`INSERT 0 1` — against the same database. So the block is before the query.

**The image and its configuration are fine.** The deployed service's own image, with the same
configmap and secret, run as a bare Job — where no NetworkPolicy selects it — answered
`{"id":"ch_156941","accepted":true}` in 52 ms. An arm with the hostname replaced by the resolved
IP behaved identically, so DNS is not involved. The same held for a second arm.

**The policy is the difference.** `charge-svc-netpol` allows egress to DNS, the `redpanda`,
`postgresql` and `monitoring` namespaces, and its declared peer — and to nothing else. The
database is a managed RDS instance, which is in no namespace, so its port is dropped.

## Single-variable proof

Adding one egress rule — the cluster's VPC range on 5432 — to the deployed service's policy:

```
POST to the deployed service with the managed-database egress allowed:
{"id":"ch_506316","accepted":true}
  http 202 after 1.094830s
```

and with the same rule on the worker's policy, the complete contract:

```
health: ok
charge: {"id":"ch_060456","accepted":true}
notifications attempt 1: [ … {"charge_id":"ch_060456", …} … ]
read-back: the worker's row is visible to the service
```

Charge accepted → consumed from Kafka → written to PostgreSQL → served back. That is the whole
transaction the row exists to demonstrate, passing on AWS for the first time.

Both experimental patches were then removed, and the specimen was left exactly as Sol rendered it
(three egress rules per policy, verified by count).

## Attribution and status

Attempt 32's FND-0073 and this are the same defect, now located: the rendered NetworkPolicy does
not describe a managed database, so a cluster that enforces it silently drops the service's
database traffic. Filed as **FND-0075** with the evidence, the enforcement asymmetry that explains
why the identical GCP contract passed, and the three candidate mechanisms for supplying the
database's range — the choice of default reachability belongs to the operator.

FND-0074 (unencoded password in `POSTGRES_URL`) is unrelated to this hang: this run's password is
alphanumeric, so the URL parses exactly as intended.

The specimen is not a qualification run: it was patched experimentally to prove the mechanism, and
that patch is not the product fix. It is torn down through the supported lifecycle, so AWS's
remaining work is the egress rule plus one clean fresh row.
