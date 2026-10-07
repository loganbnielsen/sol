# Alpha.11 AWS campaign: fails closed at the contract-reconciliation TLS step (2026-10-07)

Specimen: release candidate `v0.1.0-alpha.11`, revision
`0020f84a5cea0d80cd196f7dccab1b5c43c916d6`, bundle
`sol-v0.1.0-alpha.11-linux-x86_64.tar.gz`
(sha256 `836aec002616b024e77ce091b5d72d9415037158307430adfc5766a8e219b8de`), migration runner
`ghcr.io/sol-fab/sol-migration-runner@sha256:d6cd25ca4cdb010b7b585784c34f8fa72132f51122e25d93068bb53e0f2d6d8d`.
Target `qualalpha11/aws/us-east-1`, cluster `sol-qual-a11`, account `876701109436`,
region `us-east-1`. Operator identity: SSO `sol-qual`
(`arn:aws:sts::876701109436:assumed-role/AWSReservedSSO_AdministratorAccess_…/logan`).
Attempt `alpha11`; evidence directory `/tmp/sol-aws-row-alpha11`; run started 2026-10-07T05:20Z.

## Outcome

**No alpha row is qualified.** The AWS application row failed closed at `sol deploy`'s contract
reconciliation Job (row **B1**); the campaign stopped there, GCP was not started, no
`qualification-verdict.json` was produced, and alpha.11 was not promoted.

The alpha.11 migration-runner gate did what #1272 intended: candidate construction passed its
anonymous fresh-cluster check, and `sol migrate apply` pulled the recorded public digest on the
fresh specimen.

## What passed (independently observed)

| Row | Observation | Evidence |
|---|---|---|
| I1/I2 | `sol cloud bootstrap` reported the durable installation established; `sol cloud apply` reached `lifecycle phase: Ready`; platform converged | `cloud-bootstrap.log`, `cloud-apply.log`, `cloud-apply-resume.log` |
| I3 (partial) | authority de-escalated: `de-escalation verified as arn:aws:iam::876701109436:role/sol-qual5-cluster-access`; the identity boundary held (`deploy creates rolebindings, cluster-access does not`) | `cloud-apply-resume.log`, `harness.log` |
| substrate | four `m6i.xlarge` nodes `Ready` via the cluster-access identity | `nodes.log`, `k8s-nodes.txt` |
| C1 | `Migrations: OK -- 7 declared migration(s) present in schema_migrations`; the Job used the release's digest-pinned public runner | `app-deploy.log` |
| H6 | after teardown, `absence.py` read every required disposable class **ABSENT**; the durable zone was retained | `aws-inventory.txt`, `aws-inventory-verdict.txt` |

Redpanda itself was healthy: three brokers `2/2 Running`, and the schema registry's chain verified
against the deployment CA from inside the cluster
(`openssl s_client … Verify return code: 0`, `curl --cacert … https://redpanda.redpanda.svc.cluster.local:8081/subjects → 200`).

## The failing observation (B1)

`sol deploy` failed at the contract reconciliation Job `sol-contract-1791353221368`
(`pluto-comms`), per topic:

```
contract OrderPlaced: schema registry for topic orders.v1: set compatibility:
kafka_service: TLS failure: authentication failure: invalid certificate chain
```

Deploy exited non-zero and rolled out no workload.

## Ownership: product (framework/support-library HTTPS trust)

The Job's client is `framework/ocaml/kafka-eio-service/lib/kafka_service_http.ml` →
`Https_eio.request`. `https-eio` (pinned `e548f47c`, release 0.1.1) builds its TLS configuration
exclusively from `Ca_certs.authenticator ()` — the OS trust store — and exposes no CA input. The
Job's `KAFKA_SSL_CA_LOCATION=/etc/sol/kafka/ca.crt` is consumed by the Kafka broker client, not by
the HTTPS client, so OCaml-TLS rejects the platform's private root (`X509.Validation` →
`` `InvalidChain ``). The platform side is correct. Filed as **#1274**.

## Deviations

1. **Target `kube_context` corrected between phases.** The operator target first declared
   `kube_context: sol-qual-a11`; `sol cloud apply` printed the deploy context
   `sol-qual-a11-deploy` and the harness aliases it `<cluster>-deploy`. `sol secret set` resolves the
   declared context in the ambient kubeconfig, so the app phase initially failed with
   `context "sol-qual-a11" does not exist`. Corrected to `sol-qual-a11-deploy`; the cloud phase
   evidence is at the earlier value. This is operator target configuration, not a product defect.
2. **Teardown required matching the applied zone setting.** The deploy's substrate reconciliation
   created a second public `qual-aws.sol-fab.dev` zone (cluster root default
   `create_route53_zone=true`), so `sol cloud destroy` with the row var-file (`false`) could not
   plan (`multiple Route 53 Hosted Zones matched`). Destroy was completed with
   `create_route53_zone=true`, which removed the duplicate. Filed as **#1275**.
3. **`--accept-unreleased`.** The first destroy attempt tore the platform root down before the
   cluster root plan failed on the zone error, removing the `sol-deploy` ClusterRole; the deploy
   identity could then no longer enumerate deployments, so the supported release check could not be
   satisfied. `sol cloud destroy … --accept-unreleased` was used, recording that the independent
   absence check, not the release, decided the outcome. No workloads had been rolled out (the
   deploy failed at contract reconciliation).

## Teardown and absence

`sol cloud destroy` reported *"Destruction reached verified absence."*. Independent inventory of
the account (not Sol's report) read EKS cluster, RDS instance/subnet group/snapshots, EC2
instances, VPC, NAT gateway, elastic IPs, EBS volumes, load balancers, ECR repositories, IAM roles
and policies, S3 buckets, CloudWatch dashboards and log groups **ABSENT**. The durable
`qual-aws.sol-fab.dev` zone (`Z0555133LN4ZIDB3U52A`) was retained with its four nameservers
unchanged (`ns-1335`, `ns-803`, `ns-1560`, `ns-485`), and the durable state bucket, lock table and
six IAM roles were untouched.

## What this record does not establish

Anything about GCP, and every row the run did not reach — they stay `NOT RUN`. It is not
qualification evidence for alpha.11 (no row passed), and it says nothing about alpha.9 or alpha.10,
whose observations were not reused. The two defects are implementation work for the defect-fix
agent; the immutable alpha.11 candidate was not patched and no campaign-only workaround was
introduced.
