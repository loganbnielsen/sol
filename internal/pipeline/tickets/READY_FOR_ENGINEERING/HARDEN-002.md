---
id: HARDEN-002
type: verification
severity: high
title: Build and run production-single-region conformance
source: production platform contract review 2026-09-16
---

**Depends on:** FEAT-089, FEAT-050, AUDIT-080, AUDIT-069, AUDIT-072, AUDIT-078, SEC-004, OBS-043, FEAT-088.

## Goal

Turn the guarantees of the versioned `production-single-region` profile into one
executable qualification run and a reviewable evidence bundle. This is the
conformance epic; it does not invent guarantees or reimplement their mechanisms.

## Minimal harness

Use the existing deployment plan, release/deployment records, CLI status and
golden-path infrastructure. Add only the orchestration needed to create an
isolated qualification target, run scenarios, collect evidence and tear it down
safely. Do not build a generic certification service.

The evidence bundle records:

- profile and supported component versions;
- resolved target identity and selected reconciliation authority;
- workload artifact digests;
- scenario start/end, outcome and relevant diagnostics;
- restore point/result and measured recovery/data-loss observations;
- alert-delivery acknowledgement; and
- explicit skipped capabilities that the workload does not use.

## Required scenarios

1. Fresh provision and normal deployment.
2. Deliberately failed deployment.
3. Rollback to the prior compatible release.
4. Node drain and unplanned node loss for workloads claiming tolerance.
5. Postgres loss and Kafka/broker loss for capabilities in use.
6. Database/application-data restore into a clean target.
7. Runtime credential rotation and old-credential revocation.
8. Synthetic alert delivery and acknowledgement.
9. Drift detection or correction according to DEC-027.
10. One representative application transaction after each recovery.

## Acceptance criteria

- One command or documented CI job runs the complete required qualification for
  the selected profile without manual result editing.
- A failed required scenario returns non-zero and marks the evidence bundle
  non-conformant.
- Evidence distinguishes implementation/config inspection from live behavioral
  proof; static YAML assertions cannot pass a failure scenario.
- The run is repeatable on a clean target using only the declared compatibility
  matrix and named credentials.
- Secrets are redacted and teardown is independently verified.
- The resulting evidence is sufficient for PROD-001's launch review.

**Demo/example coverage:** Run against the same readable production-profile
example used for the pilot, not a hidden test-only workload.

**TypeScript parity:** Run the language set selected by DEC-026. If both are in
scope, both must execute representative deployed behavior; shared substrate
failure scenarios need not be duplicated without value.

## Progress (2026-09-17) — run 1 against a real AWS target: BLOCKED

Executed against a disposable AWS EKS target in an isolated account (account id and
profile names deliberately not recorded here), region us-east-1, production-shaped:
3 AZs, 4x m6i.xlarge managed nodes, RDS Multi-AZ requested, Redpanda RF3 +
persistence, remote state + scoped identities. The executable matrix derived from
DEC-026 is `docs/qualification/production-single-region-v1-matrix.md`.

**Status: non-conformant. Blocked before scenario 1 (fresh provision + normal
deploy) could execute — no numeric DEC-026 target could be measured.**

### Blocker (needs a decision before this ticket can pass)

`Postgres_durability` and `Kafka_durability` are still mapped to
`not_yet_established` in `cli/sol/lib/sol_cli_profile_preflight.ml`
(`Unmet (Platform, "Sol cannot establish this guarantee for any target yet")`), so
**every** target selecting `production-single-region/v1` fails preflight on two
guarantees the profile claims (DEC-026 §4 requires exactly these two target-side
validation checks, and §5 fixes their bounds):

```
$ sol deploy qual/aws/us-east-1 --dry-run --image-tag probe
error: this target selects profile production-single-region/v1, and preflight found 4 unmet guarantee(s). Nothing was changed.
  - qualified version set is not established [application]: order_svc declares language typescript ... (DEC-026 §2)
  - immutable artifact identity is not established [application]: ... pass --image-ref ... (FEAT-050)
  - Postgres durability is not established [sol]: Sol cannot establish this guarantee for any target yet
  - Kafka durability is not established [sol]: Sol cannot establish this guarantee for any target yet
```

The first two are correct behaviour and were recorded as passing negative cases.
AUDIT-078 implemented the *mechanisms* (Redpanda RF>=3 verified through the admin
API, `SOL_KAFKA_DURABILITY` wiring, `rds_multi_az` derived from the profile) but the
preflight never gained the branches that establish the two guarantees, so the
profile fails closed on its own capability.

Deliberately **not** done: the preflight was not relaxed, the contract was not
edited, and the check was not bypassed.

### Additional defects found by this run

1. **`sol cloud apply` crashed before running terraform** — the run-log prune pass
   deleted the run directory it had just created (prune ordered whole run ids
   lexicographically across differing command prefixes). Fixed in PR #302.
2. **`sol cloud apply` rejects a target that sets `cluster_issuer`** — it is passed
   to the AWS provider root, which does not declare it, so terraform errors with
   "A variable named cluster_issuer was assigned on the command line, but the root
   module does not declare a variable of that name". Any target using this
   documented field cannot provision. Worked around for the run by supplying it to
   the base module only (the split the smoke harness already uses).
3. **The production Postgres path cannot provision out of the box** —
   `cli/platform/infra/aws`'s `db_password` defaults to `""` and is passed straight
   to `aws_db_instance`, so `create_rds=true` fails with
   `InvalidParameterValue: Invalid master password`. The dev/smoke harness never hit
   this because it runs `install_postgresql=false`; the RDS path had not been
   exercised live.

### Evidence (retained locally, outside the repository)

- matrix rows with `PASS` / `BLOCKED` / `NOT RUN` and the `behavioural` vs
  `inspection` tag: run `BUNDLE.md`
- preflight refusal: `40-preflight-probe.log`, summarised in
  `50-BLOCKER-preflight-durability.txt`
- scoped-identity boundary (F5): deploy identity allowed `eks:DescribeCluster`/
  `ListClusters`, **denied** `ec2:*`, `iam:*`, `eks:CreateCluster`
  (`25-f5-boundary-proof.log`)
- remote state: bootstrap S3 (versioning + AES256 + public-access block) and
  DynamoDB lock table provisioned; 12 object versions deleted at teardown
- live substrate: EKS `ACTIVE` reporting Kubernetes **1.36** (matches the module
  pin and DEC-026 §2), 4 nodes, 73 terraform resources destroyed
- teardown independently verified: EKS/RDS/VPC/LB/EIP/EBS all absent, 0
  non-terminated instances, S3 bucket and DynamoDB table gone, scoped roles deleted

Alert delivery (G1–G3) is accepted as blocked by decision: no real
production-profile receiver exists in this environment, and a local sink does not
qualify the target (DEC-026 §8).

## Remediation (2026-09-17) — run 1 blockers fixed, before spending on run 2

Run 1 stands as a valid non-conformant qualification run; its scenario evidence is
preserved. The production-path defects it exposed are now fixed, with offline
regression coverage for each.

### 1. `Postgres_durability` / `Kafka_durability` preflight (was: the blocker)

Both guarantees now have real establishment branches; `not_yet_established` is
gone and every one of the profile's eleven capabilities is established from
observable evidence.

The distinction is explicit and load-bearing:

- **Preflight establishes configuration consistency only.** Postgres: the plan uses
  Postgres, so Sol drives the provider root with `create_rds = true` and
  `rds_multi_az = true` (profile-derived) and that module renders encrypted
  storage with a 7-day PITR window. Kafka: the plan *positively declares* Kafka
  use, and every Kafka-consuming workload carries the rendered
  `SOL_KAFKA_DURABILITY=single-broker-loss` requirement that `kafka-eio-service`
  verifies against the broker. A provider that does not implement the path fails
  closed, naming what is missing.
- **HARDEN-002 establishes the behaviour.** Failover, PITR restore, zero acked-message
  loss on a broker loss and the resume bound remain live scenarios; preflight does
  not observe and does not claim them.

Missing-declaration cases stay fail-closed through the existing application
findings (a plan with migrations but no `postgres` resource; a Kafka-using service
without a `kafka` resource), which are reported ahead of these branches.

### 2. `cluster_issuer` routing

`Sol_cli_config.terraform_vars` no longer sends `cluster_issuer` to the provider
root — it is a `cli/platform/infra/base` variable, applied with its own variables
(the split the smoke harness already used). A documented target using it can
provision again. Covered by a regression test asserting the field is not routed to
the provider root while provider-root variables still are.

### 3. Fresh production Postgres provisioning

`create_rds = true` can no longer send an empty master password to AWS:

- `Sol_cli_db_credential` (pure, unit-tested) refuses an apply that would create
  Postgres with no credential source, and refuses a password passed with `--var`
  because the run log records the terraform command line;
- the credential comes from `TF_VAR_db_password` (environment, from the operator's
  secret store), which Sol never logs, and `sol cloud apply` fails before terraform
  runs at all;
- `aws_db_instance.postgres` carries its own precondition on password strength, so
  the constraint holds when terraform is driven directly;
- nothing writes the value to a plan, output, log or release record; the module's
  `postgres_url` output was already `sensitive`.

**Deliberate non-decision, flagged for the user:** Sol does *not* yet own
generating or storing this credential (e.g. AWS Secrets Manager, or writing it
into the runtime Secret). Today the operator supplies it and Sol transports it out
of band. Whether Sol should own that lifecycle is a real architectural choice and
is *not* decided here.

### 4. `qualified_versions` stays fail-closed

Untouched. The TypeScript rejection is a valid negative case under the OCaml-only
`v1` qualification (re-verified after remediation). The conformant run uses an
OCaml-only representative workload — `examples/pluto` minus its two TypeScript
services — rather than weakening FEAT-088.

### Offline coverage added (before any second AWS run)

| Defect | Coverage |
|---|---|
| Empty/insecure RDS credential reaching AWS | `test_db_credential.ml` (8 cases: missing, empty env, argv refusal, argv refusal even with env set, non-Postgres provider, source) |
| `cluster_issuer` routed to the provider root | `test_config.ml`: `terraform vars: cluster_issuer stays in the base layer` |
| Durability guarantees unestablishable | `test_profile.ml`: established for a qualified target, Unmet for an unqualified provider, Unmet(Application) for a consumer missing the rendered requirement |
| Module-side password guard | `check_production_infra.sh` runtest: structural precondition check + `terraform fmt -check` (offline HCL parse) |

### Acceptance check (offline, no AWS spend)

- Production-profile `--dry-run` with the OCaml-only workload and per-service
  `--image-ref …@sha256:…` references: **passes** (exit 0, no unmet guarantees).
- Fail-closed properties re-verified: a TypeScript workload still fails
  `qualified_versions`; a mutable tag still fails `immutable_artifacts`; a
  password-less RDS apply is refused before terraform runs.

### Run-1 evidence review (what survives, what is superseded)

| Run-1 evidence | Status |
|---|---|
| Scoped-identity deny/allow proof (deploy identity allowed `eks:DescribeCluster`/`ListClusters`; denied `ec2:*`, `iam:*`, `eks:CreateCluster`) | **Valid** — the bootstrap-generated policies and the attached roles are unchanged by this remediation |
| Remote state: versioned/encrypted/public-access-blocked bucket + DynamoDB lock, 12 versions deleted at teardown | **Valid** — the bootstrap module is unchanged |
| Live substrate facts: EKS ACTIVE reporting Kubernetes 1.36; 4 nodes; 73 resources destroyed; teardown independently verified | **Valid** — substrate evidence, unaffected |
| TypeScript fails `qualified_versions`; mutable tag fails `immutable_artifacts` | **Valid** — re-verified after remediation |
| Preflight refusal on `postgres_durability`/`kafka_durability` (`40-preflight-probe.log`) | **Superseded as current behaviour, retained as defect evidence** — those capabilities are now established |
| `sol cloud apply` aborting on `cluster_issuer` (finding 2) | **Invalidated as behaviour** (routing changed); retained as defect evidence, now covered by a regression test |
| RDS creation failing on the empty password (finding 3) | **Invalidated as behaviour** (input now refused earlier); retained as defect evidence, now covered by tests |
| `sol cloud apply` run-log self-prune crash (finding 1) | Already fixed and merged (#302) |

### Proposed run-2 matrix delta

1. **Workload**: the OCaml-only qualification workload (pluto minus `demo_ts`), so
   the OCaml scope is conformant; the TypeScript rejection stays a recorded
   negative case rather than being part of the conformant plan.
2. **Provisioning**: supply `TF_VAR_db_password` from a secret at apply time; do not
   set `cluster_issuer` on the provider-root apply (pass it to the base module).
3. **Postgres**: add the fail-closed negative first (apply without the credential
   must refuse before terraform), then the positive path; then E1's Multi-AZ
   inspection, and E2/E3/E4 measurements.
4. **Kafka**: E7 now also records the rendered `SOL_KAFKA_DURABILITY` requirement
   on each consuming workload (the thing preflight asserts) alongside the live RF
   check, so the config assertion and the behavioural proof are visibly distinct.
5. **New rows worth adding**: (a) `sol cloud plan` on a target that sets
   `cluster_issuer` completes without a terraform variable error (the routing
   regression, live); (b) an apply that would create Postgres with `--var
   db_password=…` is refused (leak guard, live).
6. **Unchanged**: the DEC-026 numeric targets, the alert-delivery rows (still
   blocked for lack of a real receiver), and the evidence-bundle schema.

## Run 2 (2026-09-17) — approved production-shaped AWS run: five production-path defects

Run 2 executed against a fresh disposable production-profile AWS target (EKS 1.36,
3 AZs, 4x m6i.xlarge, RDS Multi-AZ, remote state, scoped identities). Run 1's
remediations were **verified live**:

- RDS was created (run 1's empty-password failure): `available`, `MultiAZ = true`,
  `StorageEncrypted = true`, `BackupRetentionPeriod = 7` (the DEC-026 §5 PITR window).
- `cluster_issuer` was declared on the target through the **normal documented path**
  and `sol cloud apply` completed: the Terraform argv contains no
  `cluster_issuer` and Terraform reported no undeclared variable.
- The credential was supplied only via `TF_VAR_db_password` from a 0600 file outside
  the repository; the terraform argv contains no `db_password`, and the deploy log
  contains no credential value (checked against the value itself).
- `Profile: production-single-region/v1 (preflight passed)` for the OCaml-only
  workload with per-service `@sha256` refs — the run-1 blocker is gone.
- The cluster was created with `enable_cluster_creator_admin = false` and driven
  throughout through a scoped identity (`assumed-role/…-provisioner` with a cluster
  access entry), not the cluster-creator admin.

**Status: non-conformant.** Five production-path defects were found before the
behavioural scenarios could run. None was worked around by weakening a test or
editing a claimed contract; each is preserved as evidence and recorded below.

### Finding 4 — the alert receiver the profile requires could not be rendered

`cli/platform/infra/base` failed to apply whenever alerting was configured:
`Error: Inconsistent conditional result types … the 'true' value includes object
attribute "webhook_configs", which is absent in the 'false' value`. The two branches
of `prometheus_alertmanager_config` are objects with different attribute sets, which
Terraform cannot unify — and `local.alerting_configured` is true exactly when a
receiver is declared, which the profile requires (DEC-026 §8). So the alerting
mechanism was not merely unqualified, it was uninstallable. The same file already
documents this trap for its Thanos config.

**Fixed** (minimal): the unconfigured branch carries `webhook_configs = []`, so the
branches unify; a null receiver with no integrations is valid Alertmanager config.
This establishes mechanism/configuration correctness only — **G1-G3 remain blocked**
for lack of a real receiver, and fixing this does not qualify delivery or
acknowledgement.

### Finding 5 — the documented base-platform install fails on a fresh cluster

The documented operator procedure (`docs/guides/TUTORIAL.md`: one
`terraform apply` in `cli/platform/infra/base`) fails with
`API did not recognize GroupVersionKind from manifest (CRD may not be installed)`
for `kubernetes_manifest.letsencrypt_{staging,prod}`. The module's own intent is a
single apply (`depends_on = [helm_release.cert_manager]`), but `kubernetes_manifest`
resolves the GVK at **plan** time, so `depends_on` cannot order it against a CRD
installed by the same apply. The only working sequence (apply cert-manager, then the
rest) lives in `devtools/aws-live-smoke.sh` — a devtool workaround that never reached
the documented path. Verified: **no `cli/sol` code path drives
`cli/platform/infra/base`** at all; it is operator-run Terraform.

**Remediation direction:** the normal public provisioning path must own the
sequencing (establish cert-manager + CRDs, wait/verify the CRDs, then the
CRD-dependent resources), reusing the staging the devtool already has. A regression
must assert the *orchestration boundary* separates CRD installation from
CRD-dependent resources — an HCL `depends_on` assertion would have passed while the
real operation failed. Not yet implemented.

### Finding 6 — no named identity can publish workload images

The provider module creates the workspace's ECR repositories, and FEAT-050 requires
the published digest to exist before deploy, but no identity in the contract can
publish: the provisioner policy has no `ecr:*` at all (`ecr:DescribeRepositories` is
denied: "no identity-based policy allows…"), the deploy policy allows only
`eks:ListClusters`/`DescribeCluster`, and the operator is read-only. The provisioner
creates what it cannot use. Either the provisioner needs push rights scoped to the
workspace repositories, or the contract is missing a publisher/CI identity.

**Run-2 deviation (recorded):** images were published with the operator's own
credential, a broader identity than the contract names, so the publish step is **not**
qualified against a scoped identity in this run. Not yet remediated.

### Finding 7 — the qualified substrate cannot host a persistent workload

Redpanda (3 replicas, default `redpanda_persistent_storage = true`) never scheduled:
`0/4 nodes are available: pod has unbound immediate PersistentVolumeClaims` /
`FailedBinding … no persistent volumes available for this claim and no storage class`,
and `helm_release.redpanda` timed out after its 600 s limit.

Cause: the substrate provides no storage. `cli/platform/infra/aws/main.tf` sets
`cluster_addons = { vpc-cni = … }` and nothing else; there is no EBS CSI driver addon,
no IRSA role for it, and no `StorageClass` anywhere in `cli/platform/` (`rg
'ebs.csi|StorageClass|gp3|ebs_csi' cli/platform/ --glob '*.tf'` → no matches). EKS 1.36
ships no default StorageClass. The repo's own smoke harness only ever installed the
platform by disabling persistence (`-var=redpanda_persistent_storage=false`), so the
substrate has never hosted a persistent Redpanda and the profile's durability claims
have never had substrate support.

Impact: E5/E6/E7 (broker loss, consumer resume, topic policy), D6/D7 (Kafka worker
readiness/liveness) and every PVC-backed scenario are **blocked**. The substrate was
deliberately **not** hand-patched with a CSI driver to force them through: the finding
is that the provisioned substrate lacks it, so measuring on a hand-augmented cluster
would misrepresent conformance. Not yet remediated.

### Finding 8 — a fresh production target cannot run its first deploy (layering defect)

`sol deploy` on the fresh target: `Profile … (preflight passed)`, then
`cannot verify the required migration state: … namespaces "pluto-checkout" not found`,
with the prescribed remedy `Run \`sol migrate apply qual2/aws/us-east-1\`, then deploy
again`. Running that remedy fails with the identical error, because nothing creates the
namespace. With the namespace created manually, the migration Job still cannot start:
`Error: secret "sol-secrets" not found`.

So the migration gate depends on **two artifacts that workload mutation creates**:
the application namespace and the runtime Secret (`sol-secrets`, carrying
`POSTGRES_URL`). The dependency is inverted — the gate requires something owned behind
the gate. Confirmed in code: the namespace is rendered inside the deployment bundle
(`sol_cli_deployment_render.ml` emits `ns_yaml` with the workloads), so there is no
`ensure_workspace_substrate` today.

This does **not** call AUDIT-069's ordering into question: creating
`namespace/pluto` is not workload mutation, and the verify-migrations-before-
workload-mutation invariant stands. The defect is that workspace substrate
initialization was assigned to the wrong lifecycle layer.

Secondary observation: three failed attempts left `configmap/sol-migrate-files-*`
behind — the cleanup path does not run when the operation fails before the Job starts
(object leak on failure).

**Remediation direction:** make the substrate explicit — a workspace-substrate step
(namespace + the workspace's runtime Secret) used by `sol migrate apply`,
`sol migrate status`/the deploy migration verification, `sol deploy` and other
workspace-scoped operations. Not a special case inside `migrate apply`. The
acceptance test is the user-facing invariant, not a unit test on namespace YAML:

> On a freshly provisioned conformant target with no application namespace, the
> documented `sol migrate apply` → `sol migrate status` → `sol deploy` sequence
> succeeds with no out-of-band Kubernetes mutation.

Not yet implemented.

### Verified in run 2 (independent of the defects)

| Row | Result |
|---|---|
| E1 Postgres Multi-AZ (inspection) | **PASS** — `MultiAZ = true`, encrypted, 7-day retention, engine 16.15 |
| A3 substrate version (behavioural) | **PASS** — EKS `ACTIVE` at Kubernetes 1.36.3; matches the module pin |
| A2/A4/A6/A10 preflight negatives | **PASS** — recorded live refusals: TypeScript (`qualified_versions`), mutable tag (`immutable_artifacts`), missing language, and headroom `1` vs **2** node-failure-tolerant workloads (`workload_availability`, DEC-026 §3) |
| §7 no standing cluster-creator admin | **PASS** — the EKS API denied the admin user; all operations ran through a scoped access entry |
| Remote state | **PASS** — bootstrap bucket (versioned/encrypted/public-access-blocked) + DynamoDB lock used by the provider root |
| F5 scoped-identity deny/allow (AWS level) | **PASS** — deploy identity allowed `eks:ListClusters`/`DescribeCluster`, **denied** `ec2:*`, `iam:*`, `eks:CreateCluster` (run 1 evidence; policies unchanged) |
| B1-B7, C1-C5, D1-D8, E2-E11, F1-F4 | **NOT REACHED** — blocked by findings 7 and 8 |

### Recorded deviations (all explicit, none silent)

1. Base platform installed with the devtool's staged sequence (finding 5).
2. The application namespace was created by hand so downstream scenarios could be
   measured (finding 8) — so anything downstream is **not** evidence that the
   fresh-target bootstrap works.
3. Images were published with the operator credential (finding 6).
4. The qualification workload is the pilot example minus its TypeScript services and
   its Kafka worker (OCaml-only `v1`, and the worker's readiness needs a broker that
   finding 7 shows cannot be hosted), with an availability claim on `checkout_svc`.

### Remediation queue before a run 3 — status reconciled 2026-09-18

Verified against current `main` (post-#311) while closing out the surrounding
Maturity-A gaps, not by re-reading this section's prose:

1. ~~Finding 8~~ — **fixed.** `Sol_cli_substrate.ensure` exists and is called
   from both `cmd_deploy.ml:339` and `cmd_migrate.ml:462,697`; confirmed by
   reading the call sites, not just the commit message ("HARDEN-002: make the
   workspace execution substrate a layer of its own (finding 8)", #307).
2. ~~Finding 5~~ — **fixed.** `sol cloud apply`'s `cmd_cloud_tf.ml` now stages
   the platform apply itself: cert-manager first, `kubectl wait
   --for=condition=Established` on the required CRDs, then the CRD-dependent
   resources — landed as part of INFRA-022's rewrite of the AWS lifecycle
   (`bbc6ac6c`, #310), which explicitly scoped itself to "move the
   cert-manager/CRD staging from the smoke harness into the public lifecycle."
3. ~~Finding 7~~ — **fixed.** `cli/platform/infra/aws/main.tf` provisions
   `aws_eks_addon.ebs_csi_driver` + `module.ebs_csi_irsa`;
   `cli/platform/infra/base/main.tf` renders the default `StorageClass`
   (`kubernetes_storage_class_v1.platform_default`, `storage_provisioner =
   "ebs.csi.aws.com"`) — landed in "HARDEN-002: make the platform substrate
   lifecycle real (findings 7 and 9 + public destroy path)" (#308).
4. ~~Finding 6~~ — **fixed (INFRA-026).** The bootstrap root now generates a
   fourth `publisher_policy_json` contract (ECR image-push actions only, with
   an explicit deny on infrastructure/IAM/repository-lifecycle mutation), and
   the provisioner's own policy gained the ECR repository-lifecycle actions
   its terraform already needed, with an explicit deny on the data-plane
   publish actions — ADR 0002 states "provisioner must not publish images" as
   a boundary, so extending the provisioner to publish (one of the two
   options this section originally posed) was never actually a valid
   resolution once checked against that decision, not just inconsistent with
   it. No `publisher_role_arn` target field was added: `sol up` never
   touches AWS (`cmd_up.ml`: "Local-only — no target concept"), so unlike
   `deploy_role_arn` there is no Sol code path that would ever resolve one —
   production publishing happens in a CI pipeline's own `docker push`,
   entirely outside Sol. Live verification (does the publisher policy's
   deny/allow actually hold against a real account) remains HARDEN run 3's.
5. Finding 4 — already fixed; keep the runtime row blocked pending a real
   receiver, unchanged.

Findings 8, 5 and 7 no longer block a run 3 by themselves. Finding 6 and the
deploy-identity destination gap (DEC-030/INFRA-025, filed and fixed in this
same reconciliation pass — `sol deploy` now has a real, RBAC-scoped
destination to reach after `sol cloud apply`, which run 2 did not have)
change what a run 3 would actually exercise; see the HARDEN run 3 plan for
the updated scope once one exists.
