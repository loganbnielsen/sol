---
id: HARDEN-002
type: verification
severity: high
title: Build and run production-single-region conformance
source: production platform contract review 2026-09-16
---

**Depends on:** FEAT-089, FEAT-050, AUDIT-080, AUDIT-069, AUDIT-072, AUDIT-078, SEC-004, OBS-043, FEAT-088.

**See also:** HARDEN-004 — the same contract realized and qualified on GCP. It is a
separate workstream (different mechanisms, same guarantees), and its per-attempt
evidence lives in `docs/qualification/gcp-bootstrap-inventory.md`. Changes to the
shared platform definition or to provider-neutral lifecycle semantics have to keep
both tickets' contracts, so a change here that looks AWS-local is worth checking
against that ticket.

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
11. Lifecycle phase, authority and desired-state policy (ADR 0003; matrix section
    I): privileged installation authority present only during the install, revoked
    after verified `Ready`; `Ready` policy in force only in `Ready`;
    `PlatformUpdating` re-entry and return to `Ready`; destroy under the Destroy
    policy; and public destruction of a failed or partially installed target.
12. Abort/resume of the destroy lifecycle (matrix rows I10–I12): a target whose
    platform install did not complete is still destructible through Sol, and an
    interrupted destroy can be resumed.

Scenarios 11 and 12 were added for Run 5: they are the lifecycle contract the
model now defines, and they are the only scenarios whose *state* is deliberately
not a healthy one.

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
- The lifecycle contract (matrix section I, ADR 0003) is qualified in the same
  run: the phase reported at each step is paired with an independent observation
  of the authority and policy actually in force, and a failed/partially installed
  target is shown to remain destructible through Sol's own public lifecycle —
  with no out-of-band resource deletion anywhere in the run.
- Every live assertion names the artifact it must retain, so a reader can check
  the claim without re-running anything (matrix rows I1–I13 and the run-identity
  lifecycle-phase record).

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

### Remediation queue — status reconciled 2026-09-18 (written before run 3)

**Historical.** This queue was written when "run 3" was the next run; runs 3 and 4
have since executed (see below), so read the finding numbers here as pre-run-3
state, not as the current plan.

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
   deny/allow actually hold against a real account) was not settled for run 3
   and **remains open for Run 5** — matrix row F5.
5. Finding 4 — already fixed; keep the runtime row blocked pending a real
   receiver, unchanged.

Findings 8, 5 and 7 no longer blocked the next run by themselves. Finding 6 and
the deploy-identity destination gap (DEC-030/INFRA-025, filed and fixed in this
same reconciliation pass — `sol deploy` now has a real, RBAC-scoped destination
to reach after `sol cloud apply`, which run 2 did not have) changed what that run
would actually exercise; see the Run 5 procedure below.

## Run 3 and Run 4 (executed 2026-09-18) — findings and remediation

Runs 3 and 4 were executed against disposable production-profile AWS targets. Both
were **non-conformant**, and their findings are what ADR 0003 and INFRA-028/029
answer. This section records what the repository records, and states plainly what
it does not, so that Run 5 does not depend on knowledge that exists only outside
the tree.

### Where each finding is recorded

| Findings | Defects | Remediation | Recorded in |
|---|---|---|---|
| 10, 11, 12 | `aws_outputs_of_json` crashed on an absent optional Terraform output (blocked apply and destroy); `target.deploy_role_arn` was never routed to the provider root, so the deploy EKS access entry was never created; the platform root resolved the **ambient** `~/.kube/config` because `hashicorp/kubernetes` reads `KUBE_CONFIG_PATH`/`KUBE_CONFIG_PATHS`, not `KUBECONFIG` | INFRA-028: the parser treats an absent optional like a null; `deploy_role_arn` is routed; `provisioner_kube_env` sets all three variables | INFRA-028 §Remediation and §Evidence; unit tests `test_outputs_absent_optional`, `test_terraform_vars_route_deploy_role_arn`, `test_provisioner_kube_env` |
| 13 | the bounded steady-state provisioner could not create the deploy identity's `sol-deploy` ClusterRole — Kubernetes' RBAC privilege-escalation check forbids granting permissions the creator does not hold | INFRA-028 / ADR 0003 invariant 1: the whole platform apply runs under the privileged installation authority, and the interim RBAC staging in `platform_prerequisite_targets` was reverted | ADR 0003; `check_production_infra.sh` (bind scoped to `sol-deploy`, no `escalate`) |
| 14 | the same check rejected third-party chart RBAC (the prometheus chart's `prometheus-server` ClusterRole) because the full platform apply ran **after** the temporary cluster-admin association had been removed | ADR 0003 invariant 1: the association spans the full apply **and** verified readiness, and is revoked only at the verified transition to `Ready` | ADR 0003; offline harness assertion that a first install reports `PlatformInstalling` |
| 15 | `sol cloud destroy` prepared destruction (protection off, unique final snapshot, verified) and then re-applied ordinary production desired state before destroying, restoring `rds_deletion_protection=true` and stranding the instance — public destroy could not complete | ADR 0003 invariant 4 / INFRA-023: from verified `PreparingDestroy` the Destroy policy governs, with its overrides appended after the profile's `rds_deletion_protection=true` | ADR 0003; offline harness assertion that the post-prepare bootstrap-admin apply carries the Destroy policy |

The two rules that contradicted each other before ADR 0003 — BUG-039
(`production-single-region/v1 -> rds_deletion_protection = true`) and INFRA-023
(`PrepareDestroy -> rds_deletion_protection = false`) — are now reconciled by
*which phase is in force* rather than by either rule weakening.

### What is **not** recorded in the repository — an explicit gap

The repository does **not** contain the run 3 or run 4 evidence bundles. Runs 1
and 2 are summarised above with their retained evidence; runs 3 and 4 are not, and
in particular there is no record here of:

- their bundles, run identities, or per-row matrix outcomes;
- which of findings 10–12 came from which run (INFRA-028 attributes 13–15 to run 4
  and records 10–12 as fixed on the same working tree);
- any measured value from either run;
- an independently verified teardown record for run 4.

**Consequence for Run 5: it may not cite runs 3 and 4 as qualification evidence.**
They are defect-discovery history, not conformance. Run 5 re-establishes every
claim from a fresh target against the matrix, which is the governing rule anyway —
a claim is per (target, profile version, timestamp). This gap is recorded rather
than closed because the bundles are not in the tree and cannot be reconstructed
from it.

## Run 5 attempt 1 (executed 2026-09-18) — NON-CONFORMANT: finding 16 blocking

First attempt at the Run 5 procedure below, against a fresh disposable target in the
qualification account (`cloud/aws/us-east-1`, cluster `sol-qual5-2ca50d57`,
`production-single-region/v1`, 111122223333 / us-east-1).

### Outcome

CloudBootstrap and the cloud substrate **succeeded**; the platform install **failed
and could not reach `Ready`**, so the attempt is non-conformant and was stopped
rather than continued into deploy/fault-injection scenarios on a non-conformant
platform. It was then torn down through Sol's public path and independently
verified absent.

| Stage | Result |
|---|---|
| `sol cloud plan` | clean, read-only; profile-derived vars correct |
| `terraform-apply` (cloud substrate) | **ok**, 849.7s — EKS `ACTIVE` at v1.36 (matches the module pin), RDS Multi-AZ with deletion protection, 5 ECR repos, dedicated VPC |
| `platform-prerequisites-apply` | ok, 49.5s |
| `platform-apply` | **FAILED**, 701.1s — the blocking finding |
| `provisioner-bootstrap-access-remove` | ok, 13.8s (privilege relinquished anyway) |

### finding 16 — blocking production defect

```
helm_release.redpanda: context deadline exceeded
helm_release.loki[0]:  context deadline exceeded
0/3 nodes are available: 3 Insufficient cpu.
```

Measured cause: the node group came from the provider root's **defaults**
(`node_instance_types = ["m6i.large"]` = 2 vCPU, `node_desired_size = 3`) → 6 vCPU
total, while the platform's own RF≥3 Redpanda requests **2 vCPU × 3 brokers = 6
vCPU by itself**; `loki-chunks-cache-0` was `Pending` for the same reason. This
section's own minimal harness already specifies "4x m6i.xlarge" — nothing enforced
it. Remediated by INFRA-030 (the profile now owns a capacity contract, with the
contract expressing capacity rather than an instance type).

### findings 17 / 18 — the matrix claimed more than the CLI could show

- **finding 17**: `CloudBootstrap`, `Ready` and `Destroying` were never operator-visible;
  only `PlatformInstalling`, `PlatformUpdating`, `PreparingDestroy` and `Absent`
  were ever printed. Rows I1/I3/I9 assert the others. Remediated by **INFRA-031**
  (report them where the lifecycle enters them) — the specification was *not*
  weakened to match the gap.
- **finding 18**: row I3 asserted a negative `can-i` for `create clusterroles` /
  `create clusterrolebindings`. The live attempt showed `create` is **permitted**
  by design (scoped platform management needs it) while `escalate` and `bind` are
  **denied**, which is the real boundary. Row I3 corrected accordingly.

### Alloy — recorded, not filed as a defect

`helm_release.alloy` failed with `could not download chart: Chart.yaml file is
missing`, but the pinned version (`1.12.1`) **exists** in the repository, so this
is treated as a transient download/extraction failure until a clean attempt
reproduces it. Filing a product defect on it now would be guessing.

### Positive evidence established (live behavioural)

These are legitimate live qualifications in their own right, even though the
attempt as a whole is non-conformant:

- **`lifecycle phase: PlatformInstalling`** reported during the platform apply;
- **temporary privileged authority was relinquished on a *failed* platform
  install** — the safe failure mode, rather than leaving cluster-admin behind;
- **ADR 0003 invariant 2 holds live**: after de-escalation `escalate clusterroles`
  and `bind clusterroles` both **denied**, `associatedAccessPolicies` **`[]`**,
  and cluster-wide reads `Forbidden`;
- **ADR 0003 invariant 6 / INFRA-029 holds live, on a real failure**: the target
  never reached `Ready`, yet `sol cloud destroy` entered
  **`lifecycle phase: PreparingDestroy`** and destroyed the partially installed
  target. The abort edge did real work here rather than being argued about;
- **finding 15's destroy-policy ordering** produced a real, uniquely named final
  snapshot that was confirmed `available`;
- **command completion is not infrastructure truth**: immediately after Sol
  reported `Done.`, describe calls still showed 3 EC2 instances and a NAT gateway,
  which were gone on subsequent observation. The plan's independent verification
  requirement earned its place here.

### Cost-clean verification

Independently verified after teardown with describe calls: EKS `list-clusters` empty,
RDS 0, ECR 0, non-default VPCs 0, ELBv2 0, EIPs 0, EBS volumes 0, NAT gateway
`deleted`, instances `terminated`. The disposable final snapshot was retained only
until this record captured its identifier and status, then deleted
(qualification-account hygiene; **Sol's production destroy behaviour is unchanged**
and still creates and preserves the required final snapshot).

### Attempt-2 preconditions

findings 16 and 17 must be on authoritative `main`, the complete offline gate green, and
this procedure re-read end to end. The profile's capacity contract means a conformant
attempt expects **4 × m6i.xlarge**; a target that provisions anything smaller is now
refused by preflight rather than discovered as `Insufficient cpu`.

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

## Run 5 attempt 3 (executed 2026-09-19) — NON-CONFORMANT: finding 20 blocking

Fresh disposable target `sol-qual7-3904198d`, after INFRA-032 was on `main`.

| Stage | Result |
|---|---|
| `terraform-apply` (cloud) | **ok**, 860.3s — EKS v1.36.4 `ACTIVE`, 4 nodes |
| `platform-prerequisites-apply` | ok, 49.4s |
| `platform-apply` | **ok**, 171.0s — **every chart installed, alloy included** |
| `provisioner-bootstrap-access-remove` | ok, 13.6s |
| platform readiness | **FAILED** — every component reported unavailable |

### finding 20 — a fresh install is judged by one readiness sample (INFRA-034)

`platform-apply` succeeded and then readiness reported **nine** components as
unavailable, immediately. Minutes later, on that same target: cert-manager 3 × `1/1`,
ingress-nginx `1/1`, Argo CD 7 × `1/1`, Redpanda 3 × `2/2`, Alloy 4 × `2/2`,
Loki/Grafana/Tempo/Prometheus all ready, four nodes `Ready`. The gate sampled once the
instant the apply returned and never re-checked; `readiness` contains no wait, retry or
sleep. Helm reporting a release as deployed means the objects were created, not that
the controllers behind them are serving, so a single sample cannot describe a fresh
install. Fixed by INFRA-034 (bounded wait, progress reporting, same fail-closed
outcome on timeout).

The run relinquished privilege before reporting the failure, so the operator is told
the target failed when the platform is fine.

### The one check that could not have fixed itself, and a fixture pitfall

Of the nine, the `ClusterIssuer` had a different and genuine cause: Let's Encrypt
rejected the ACME registration (`ErrRegisterACMEAccount`) because the contact email's
domain is on LE's forbidden list — `contact email has forbidden domain "example.com"`.
The qualification target file had been given a documentation-style address
(`…@example.invalid`, then `…@example.com`), and **no reserved documentation domain can
ever satisfy this check**. A qualification target must use a syntactically valid,
non-forbidden domain; verified against the live ACME server that
`qualification@sol-harden-qualification.dev` registers (`ACMEAccountRegistered`).

This is a fixture-input error, not a product defect — but it is recorded because it
cost two attempts, and because the readiness summary reporting nine components at once
is what made the real cause hard to see (INFRA-034's progress reporting addresses the
diagnosis half of that).

### Cost-clean verification

EKS `ResourceNotFound` and `list-clusters` empty; RDS 0; 4 instances `terminated`; NAT
`deleted`; EIP 0; ELBv2 0; EBS 0; non-default VPCs 0; ECR 0. Final snapshot recorded
then deleted.

## Run 5 attempt 5 (executed 2026-09-19) — CONFORMANT through Ready

**Result: the first conformant install of the run.** Authority: `main @ 852be182`,
verified before the run; the binary was built from that tree and its mtime did not
change during the attempt. Target `sol-qual9-86054342`, account `<qualification account>`
(the recorded precondition-1 deviation still applies).

```text
lifecycle phase: CloudBootstrap      [terraform-apply] ok (884.7s)
lifecycle phase: PlatformInstalling  platform-prerequisites-apply ok / platform-apply ok (171.7s)
provisioner-bootstrap-access-remove  ok (14.0s)
lifecycle phase: Ready               Done.
```

Then, with a real platform change (`alert_owner`):

```text
lifecycle phase: PlatformUpdating    platform-apply ok (80.5s) -> Ready
```

`PlatformInstalling` appeared **zero** times on the re-apply. The change landed
(`sol-qual9-oncall` present in `configmap/prometheus-server`), so this was a real
reconciliation and not a no-op apply.

### Rows qualified (convergence)

| row | evidence |
|---|---|
| I1–I2 | `CloudBootstrap` reported before any platform mutation; privileged installation authority held through chart RBAC |
| I3 | after de-escalation: `can-i get pods -n monitoring` **yes**, `create clusterroles` **yes**, `bind clusterroles` **no**, `escalate clusterroles` **no** — the corrected row semantics, confirmed live for the first time |
| I4 | RDS `available`, MultiAZ true, `DeletionProtection: true` while `Ready` |
| I5–I6 | `PlatformUpdating` (never `PlatformInstalling`), back to `Ready`, provisioner re-verified |
| I14 | `Ready` reached under the convergence contract with no `/proxy/` probe and no issuer condition |

Convergence by inspection, not just by the gate: 4 × `m6i.xlarge`, EKS `ACTIVE`,
server `v1.36.4-eks-4cc7921`, all platform workloads Ready (cert-manager 3×1/1,
ingress-nginx 1/1, argocd 7×1/1, redpanda 3×2/2, monitoring all Ready), PVCs
Bound (monitoring 3, redpanda 3).

### Read-only networking inspection (INFRA-036) — answered

The node security group admits a **different** group — the module's cluster
security group — on 443, 4443, 6443, 8443, 9443 **and 10250 (kubelet)**, from the
module's default `ingress_cluster_kubelet`/`ingress_cluster_https` rules. So:

- **control-plane → kubelet is contract**, and Sol depends on it: the Redpanda
  readiness check runs `kubectl exec … rpk cluster health` on every apply, which
  makes each apply a direct test of the path. It already exists — nothing changed.
- **arbitrary pod/service ports are not provided**, which is why the removed
  `/proxy/` probes could never pass. The disposition is now evidence, not
  inference.

Nothing about networking was modified in response to either observation.

### Rows qualified (behavioural — distinct from convergence)

| capability | evidence |
|---|---|
| log → Alloy → Loki → query | a broker topic created during the run (`sol-harden-9cd076`) appeared in Loki within 20 s, with `namespace`/`container`/`job=loki.source.kubernetes.pods` labels. Loki canary on the same target: `entries_total=929`, `missing_entries_total=0` |
| broker produce → consume | `rpk topic create -p 3 -r 3` OK; produce → `Produced to partition 0 at offset 0`; consume → read back; `rpk cluster health` → `Healthy: true`, nodes [0 1 2] |
| E5 — acknowledged-message loss on one broker loss | 200 messages produced with `acks=all`; 200 consumed before; broker pod deleted; **200 consumed after** → 0 loss |
| metric → Prometheus → query | `count(up)=10`, `count(up==1)=10`, `count(up==0)=0`, `count(kube_pod_info)=24` |
| E2 — Postgres failover RTO | forced Multi-AZ failover, `rebooting … 78 s … available`. **Method limitation: status-level, not connection-level** — no client was deployed, so the row is partly qualified |

### Findings

| # | finding | severity | owner |
|---|---|---|---|
| 21 | `sol cloud destroy` fails after the documented publish step: ECR repositories are not `force_delete`, so images published by the lifecycle block the teardown. Auditing the class found worse on both providers — loki/thanos buckets carried `prevent_destroy = true` (terraform refuses before attempting), so a durable-observability target could never be destroyed | high | **INFRA-037 — fixed and merged (`7e81dde5`)**, with ADR 0004, a structural guard and its mutation test |
| 22 | the Kafka-durability guarantee fires because *nothing in the scope* uses Kafka, not because a service needs something the profile cannot honour. `checkout_svc` is a stateless `/quote` service, so the fixture was right and the check was wrong | high | INFRA-038 (decision required on the predicate) |
| 23 | a long-running lifecycle operation cannot reacquire short-lived credentials: the SSO refresh token expired mid-run, the CLI still answered while terraform could not, and the teardown of a *billable* target could not authenticate | high | INFRA-039 |
| 24 | a behavioural observation nearly produced a confident false finding: `kubectl port-forward svc/loki` kept serving the instance replaced by the `PlatformUpdating` rollout (366 lines vs the pod's 36,523). The canary's independent metric is what caught it | medium | HARDEN-003 |
| 25 | cost-clean required an operator to delete the final snapshot by hand, so "destroyed and cost-clean" was not zero | medium | DEC-033 |

Finding 23's direction is the dangerous one and is why it is rated high: expiry
during provisioning wastes an attempt, expiry during **teardown** strands billable
infrastructure and disables the only supported path to remove it.

### Blocked / not executed (recorded as such, not claimed)

- **B1–B7, C1–C5, ingress request→response, Tempo traces, D3** — the deploy path.
  Scoping removed the TypeScript blocker and then finding 22 stopped the scoped
  deploy. The app lifecycle remains the largest unexplored area, which is why
  Attempt 6 should be application-centric.
- **G1–G3** — no alert receiver (recorded as blocked in the matrix).
- **E3/E4** — Postgres PITR and restore-into-clean-target; not attempted in this
  budget.
- **TLS issuance** — `base_domain` is `sol-qual5.invalid`, so no public issuer can
  validate; recorded as inconclusive rather than failed.

### Deviations (explicit, not silent)

1. **Teardown identity.** The documented `sol cloud destroy` could not
   authenticate with the `sol-qual` SSO profile (finding 23). The same documented
   command was re-run with `AWS_PROFILE=Administrator`, a static credential in the
   same account. Same command, same state, no manual infrastructure edits. Filed
   as finding 23 because the fallback saved the money but must not become the
   product answer.
2. **ECR repositories force-deleted** to let the documented destroy finish
   (finding 21). These were artifacts this run published, not infrastructure.
3. **The final RDS snapshot was deleted by hand** (finding 25 / DEC-033).
4. **A behaviour measurement was wrong before it was right** (finding 24), and the
   raw sequence is preserved: the empty query, the contradiction against the
   canary, and the stale-vs-actual metric comparison.

### Retention must be stated, not inferred (DEC-033)

A disposable qualification target sets `destroy_retention: none` in its target
file before teardown. The destroy then reports `retention: none ... no residual
billable artifacts` and passes no final-snapshot identity, so "cost-clean" is a
claim the run's own output supports rather than something an operator establishes
afterwards by deleting a snapshot by hand — which is what Attempt 5 needed.

Leaving the field absent is correct for a production target: retention stays
explicit (the destroy names the snapshot and how to remove it), and a
qualification run retaining nothing never changes what destroy promises by default.

### Cost-clean verification (independent)

EKS none · RDS instances 0 · RDS manual snapshots 0 · EC2 4 terminated · NAT
deleted · EIPs none · load balancers none · EBS volumes none · VPCs none · ECR
repositories none · CloudWatch log groups 0 · Route53 zones none · S3 tfstate 2
objects (the state itself, intentional).

Evidence bundle: `~/.sol/harden-run5-attempt5/` (apply, re-apply, deploy attempts,
all four destroy attempts, the network inspection and the consolidated record).

## Run 7 attempt 7 (executed 2026-09-19) — the first migration through a cloud target

Authority `main @ 7ea2ef43`, verified to carry INFRA-040 and the DEC-033 policy
verification before the run. Target `sol-qual11-116c2637`, `destroy_retention: none`,
static `Administrator` profile (the SSO refresh token is still expired).

### Platform: CONFORMANT for the third consecutive run

```text
lifecycle phase: CloudBootstrap
lifecycle phase: PlatformInstalling
lifecycle phase: Ready        Done.
```

Platform construction is no longer where the failures are. Every finding below is
above it.

### Rows qualified

- **The migration ran and completed on a cloud target, for the first time.**
  `sol migrate apply` reached `Done.`, and `sol deploy` then reported
  `Migrations: OK -- 1 declared migration(s) present in schema_migrations`. The
  migration gate that no previous attempt could pass, passed.
- **INFRA-040 is validated live.** Attempt 6's migration Job died with
  `CreateContainerConfigError: secret "sol-secrets" not found`; Attempt 7's container
  started and ran. The Secret identity agrees with the reference.
- **DEC-033's disposable-destroy contract is qualified live.** The destroy reported
  what it selected before doing it, verified against the selected policy rather than
  a single expected value, and ended with:

  ```text
  prepare: disabling RDS deletion protection, retaining nothing...
  verify preparation: RDS deletion protection disabled, final snapshot skipped
    (skip_final_snapshot=true) (target destroy_retention = none)
  retention: none (target destroy_retention = none) -- destroyed to Absent with no
    residual billable artifacts
  ```

  Independent verification: EKS none, RDS 0, **zero manual snapshots**, EC2
  terminated, NAT deleted, EIP/LB/EBS/VPC/ECR none. The target reached `Absent` with
  no manual step — the behavioural row Attempt 6 could only reach through an operator
  deviation.

### Findings

- **INFRA-043 (high, the current blocker):** the deploy identity cannot get or create
  `sol-boundary-lease-<workspace>` — Sol's own object, held by Sol's required deploy
  identity. Every `sol deploy` stops here, one grant short of a running workload.
- **INFRA-044 (high):** a failed migration printed the full Postgres URL, password
  included, into Sol's output and the Job's logs.
- **Procedure gap:** an RDS password containing URI-reserved characters must be
  percent-encoded by the operator; the documented step does not say so, and an
  unencoded password surfaces only as `connection failed`. The password generated for
  this qualification account contains such characters, so the first run through the
  migration path hit it.
- **INFRA-040's evidence-retention item is now demonstrated live,** not just argued:
  `sol deploy` said "see the Job logs" *after* deleting them, and that deletion cost
  the live diagnosis until the same operation was re-run through `sol migrate`.

### Deviations

1. `Administrator` (static) rather than the SSO profile, which is still expired.
2. The Postgres password was percent-encoded by the operator after the first failure;
   the run continued on the encoded form.
3. The workspace's `SOL_API_KEY` is required and still absent from the procedure's
   deploy step.

### Boundary this leaves

```text
CloudBootstrap        PASS
PlatformInstalling    PASS
Ready                 PASS
Application preflight PASS
Migration Job         PASS   <- first time
Deployment lease      FAIL   (INFRA-043: missing grant)
Workload              NOT REACHED
Release / rollback    NOT REACHED
```

## Run 6 attempt 6 (executed 2026-09-19) — the application-centric attempt

**Platform: CONFORMANT for the second consecutive time.** Authority
`main @ 0791a825`; the binary was verified to carry INFRA-037/038/039, DEC-033 and
HARDEN-003. Target `sol-qual10-31012e41` with `destroy_retention: none`.

```text
credentials: arn:aws:iam::…:user/Administrator   <- INFRA-039, first live use
lifecycle phase: CloudBootstrap      [terraform-apply] ok (888.1s)
lifecycle phase: PlatformInstalling  prerequisites ok / platform-apply ok (182.7s)
provisioner-bootstrap-access-remove  ok (11.6s)
lifecycle phase: Ready               Done.
```

Infrastructure construction has become uneventful, which is the point: the
interesting failures have moved up a layer, exactly as expected.

**INFRA-039 proved itself before the run.** `sol-qual`'s SSO refresh token is
expired, so `aws configure export-credentials --profile sol-qual` failed *up front*
and the run used the static `Administrator` profile. On Attempt 5 that same
condition surfaced as a destroy that could not authenticate against a billable
target.

**INFRA-038 proved itself live.** `sol deploy --scope checkout/checkout_svc`
reached `Profile: production-single-region/v1 (preflight passed)` — the scope that
Attempt 5 could not get past preflight at all.

### Blocking finding: no workload can be deployed (INFRA-040)

The deploy failed at the migration gate with "migration-status Job did not complete
within 120s". Re-running the remedy it prescribed showed the real cause, which the
deploy's own message hid: the migration Job's container uses
`envFrom: secretRef{name: sol-secrets}`, while the substrate creates
`sol-secrets-secrets` — the right keys under the wrong name. So migrations can never
run and **no Sol workload can be deployed to a cloud target**. Filed as INFRA-040,
including the two diagnostics gaps that made it cost a second command to see (a
timeout reported instead of a failed container; the Job deleted with its reason;
a remedy that accepts no `--scope`).

### Second finding: DEC-033 does not reach the destroy (INFRA-041)

`destroy_retention: none` was ignored: the destroy took a final snapshot and printed
no retention report, so cost-clean again needed a manual deletion — the deviation
DEC-033 existed to remove. Filed with the test gap that let it through (the model
was tested; the config path and the destroy path were not).

### Teardown and absence (independent)

Documented lifecycle: prepare → `PreparingDestroy` → platform-destroy → `Destroying`
→ `terraform-destroy` ok → `Done.` Verification: EKS none, RDS 0, EC2 4 terminated,
NAT deleted, EIP/LB/EBS/VPC/ECR none, CloudWatch log groups 0. One stray manual
snapshot remained and was deleted by hand (the INFRA-041 deviation).

### Deviations

1. `Administrator` (static) rather than the SSO profile, because the SSO refresh
   token is expired. The failure was detected up front, not mid-teardown.
2. The local Docker config carried `credsStore: desktop.exe`, which fails for
   non-interactive processes in this WSL setup; `docker push` from the deploy
   therefore failed with a credential-helper error. Removed from the local config
   (Sol passes the environment through unchanged — verified — so this is
   environmental, not a product defect).
3. `SOL_API_KEY` is required by the workspace's substrate Secret and is not
   mentioned in the deploy step of this procedure.
4. The stray final snapshot was deleted by hand.

## Run 5 — procedure (executed as Attempts 5, 6 and 7; requires explicit operator authorization)

### Prerequisites the procedure assumes

Two things bit the first three executions. Both are properties of the environment,
not of the target, so they belong here rather than in a run record:

- **`POSTGRES_URL` and `SOL_API_KEY` must be in the operator's environment** before
  `sol deploy` or `sol migrate`. The deploy's own error names a missing one, but the
  workspace's secret set is not otherwise discoverable from the target file.
- **`POSTGRES_URL` must percent-encode the password.** An RDS password generated with
  URI-reserved characters (`#`, `+`, `^`, `/`, `@`) is not a valid URI as written, and
  the failure surfaces only as `connection failed` from inside the migration Job —
  with the URL echoed in full (INFRA-044). Encode it:

  ```bash
  ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PGPASSWORD")"
  export POSTGRES_URL="postgresql://postgres:${ENC}@${HOST}:5432/app"
  ```

### Where the evidence lives

Run records in this ticket are the durable account: attempts, findings, deviations,
and which matrix rows each attempt did and did not establish. A captured evidence
bundle (`~/.sol/harden-run<N>-attempt<N>/`, referenced from the run records) is
machine-local and is **not** in the repository — if the record and a bundle disagree,
the record is what other actors can see, so anything load-bearing belongs in the
record.

This section was written as run 3's proposed plan. Runs 3 and 4 then executed and
their findings changed the lifecycle model (ADR 0003), so this is now the
qualification procedure for the model on `main` and has been updated for it: the
phase, authority and desired-state-policy semantics are asserted live here, and
their matrix rows are section **I**.

**This section is preparation only.** Producing it touches no AWS account,
no Terraform state, no live target. Execution requires explicit,
present-operator authorization — the same boundary as every prior run.

### Why Run 5's achievable scope is materially larger than run 2's

Run 2's own results table recorded `B1-B7, C1-C5, D1-D8, E2-E11, F1-F4` as
**NOT REACHED — blocked by findings 7 and 8**. Since then, in this
reconciliation pass:

- **Findings 5, 7, 8** — confirmed already fixed by reading current code
  (not commit messages): cert-manager/CRD staging is now part of `sol cloud
  apply`'s own sequencing (finding 5); the AWS/base roots provision the EBS
  CSI addon, IRSA and default `StorageClass` (finding 7); `Sol_cli_substrate.ensure`
  is called from both `cmd_deploy.ml` and `cmd_migrate.ml` (finding 8). See
  the "Remediation queue" section above for the exact file references.
- **Finding 9b** (INFRA-023) — `sol cloud destroy` now disables RDS deletion
  protection through a real targeted `terraform apply` with a unique
  per-attempt final-snapshot identity, verified before destroy proceeds.
- **Finding 6** (INFRA-026) — the bootstrap root now generates a `publisher`
  IAM policy contract (ECR push only, explicit deny on infra/IAM/repo-lifecycle
  mutation); the provisioner gained ECR repository-*lifecycle* actions with
  an explicit deny on the data-plane publish actions.
- **The `sol cloud init` / deploy-identity destination gap** (DEC-030,
  INFRA-025) — `deploy_role_arn` is now wired into a real EKS access entry
  and namespace-scoped Kubernetes RBAC (a `sol-deploy` `ClusterRole` bound
  per application namespace, never cluster-wide). This is the fix that
  actually unblocks `B1` at all: run 2 had no way for `sol deploy` to reach
  the cluster as a real, RBAC-scoped identity, only run 2's ad hoc
  workaround of hand-configuring a broad credential.

So Run 5 can plausibly reach every matrix section — now including section I's
lifecycle rows, which no previous run could have asserted because the model did
not exist yet — except the alerting rows (`G1-G3`, still blocked on a real
receiver, unchanged since run 1) and whatever new defect it finds along the way.
HARDEN runs exist to find those, not to have none.

### Preconditions (must all be true before any AWS command runs)

1. A fresh, disposable, isolated AWS account/profile — never reuse any previous
   run's.
2. `cli/platform/infra/bootstrap` applied: state bucket + lock table.
3. **Four** IAM roles created by the operator (not Sol — AUDIT-072/INFRA-026:
   Sol owns the policy contracts, never role lifecycle) from the bootstrap
   root's four generated documents: `provisioner_policy_json`,
   `publisher_policy_json` (new since run 2), `deploy_policy_json`,
   `operator_policy_json`. The publisher role needs its own assume-role
   session, used by nothing else — reusing the provisioner's or deploy's
   session to publish would silently re-introduce the identity conflation
   INFRA-024/INFRA-026 exist to prevent.
4. Target file declaring: `profile: production-single-region`, region,
   `provisioner_role_arn`, `deploy_role_arn`, `operator_role_arn`, a
   `cluster_endpoint_cidr` that is not `0.0.0.0/0`, `state_bucket` /
   `state_lock_table`. Alert receiver fields only if pursuing `G1-G3`.
5. Confirm the qualification workload is still OCaml-only (Pluto minus its
   TypeScript services), matching run 2's negative-case strategy — check
   DEC-026 §2's named TypeScript-qualification triggers before assuming this
   still holds; if one has fired since run 2, that changes the workload
   selection, not this plan's mechanism.
6. A real alert receiver + owner, only if attempting `G1-G3` this run;
   otherwise they stay recorded skipped, same reasoning as runs 1 and 2
   (DEC-026 §8: a local sink does not qualify the target).
7. **The lifecycle contract is in scope for this run** (matrix section I). The
   runner must be able to capture, per `sol cloud` invocation, the verbatim
   `lifecycle phase:` line, the terraform argv (the `-var` order matters — it is
   how the Destroy policy is shown to win, row I7), and an independent
   observation for the authority in force (`aws sts get-caller-identity` and
   `kubectl auth can-i`, including **negative** checks — rows I2/I3/I5/I6).
   A run that captures the phase but no independent observation does not satisfy
   section I.
8. **A deliberate abort is part of the run, not an accident** (rows I10–I12).
   Schedule the failure-path scenarios below before final teardown: they need a
   target that exists but whose platform install did not complete, which is a
   state the run has to create on purpose. This is the one place where a
   deliberately non-conformant lifecycle state is required, and it is followed by
   a public `sol cloud destroy` — never by out-of-band resource deletion.

### Exact command sequence, mapped to `docs/qualification/production-single-region-v1-matrix.md`
### Read-only networking inspection (INFRA-036 — record the mechanism, change nothing)

Perform this before teardown, and change no networking in response to it.

`kubectl logs` succeeded on real targets while API-server access to pod and service
endpoints timed out, and the EKS module's default node-security-group rules admit
the control plane only on the admission-webhook ports (4443/6443/8443/9443). So
control-plane → kubelet is explained by something not yet read, or it is a real gap
— and that path matters well beyond readiness, because it is what `sol logs`,
port-forward and exec rely on.

Record, without modifying anything:

1. the node security group's effective ingress rules, including any rule whose
   source is the cluster security group, with ports and protocols;
2. whether the control plane can reach a node's kubelet — `kubectl logs` against a
   pod on a known node is the observable;
3. which Sol capabilities actually depend on that path, from the surfaces in
   `cli/sol/` (`sol logs`, port-forward, exec).

Then state the conclusion in exactly one of two forms:

- the path **is** part of the production contract, *because a Sol capability
  requires it* — in which case it becomes an explicit contract entry with a direct
  test; or
- it is not, in which case nothing depends on it and it is recorded as observed
  but unrequired.

Do not add or widen a security-group rule to preserve behaviour until that
question has been answered. Widening the network so a check passes is designing
the infrastructure around the test.


1. `sol cloud plan <target>` — before any apply. Verify zero mutation and
   the honest-plan invariants (Deferred vs. Plannable phases, ADR 0002).
2. `sol cloud apply <target>` — reconcile through Ready. Evidence: run log;
   separate `cloud.tfstate`/`platform.tfstate` keys; EKS `ACTIVE` at the
   pinned Kubernetes version; EBS CSI addon + default `StorageClass`;
   cert-manager CRDs `Established` before any `ClusterIssuer`; the
   provisioner's bootstrap-admin window opened then closed, with effective
   RBAC (positive **and** negative `can-i` checks) verified after
   de-escalation.
   **Lifecycle rows I1–I4 are captured from this step** and are now part of its
   pass condition, not an observer's note: the run must report
   `CloudBootstrap` before any platform mutation (I1), still hold the privileged
   installation authority after chart RBAC and the `sol-deploy` ClusterRole are
   created (I2 — this is the live check for finding 14), report `Ready` only
   after revoking that authority and verifying the bounded provisioner (I3), and
   show `rds_deletion_protection = true` in force while `Ready` (I4). "The apply
   succeeded" is not evidence for any of these: each pairs the reported phase
   with the identity/RBAC/describe observation named in the row.

   **What `Ready` means here (INFRA-036; matrix row I14).** The gate is
   authoritative Kubernetes convergence — CRDs `Established`, Deployments
   `Available`, StatefulSets/DaemonSets reporting every declared replica, PVCs
   `Bound`, nodes `Ready`, the default `StorageClass` and EBS CSI driver
   registered, the ingress endpoint assigned, and Redpanda's own broker-native
   health — and nothing else. It deliberately does not probe the platform across
   the network, and does not require an external ACME round trip. So "the target
   reached `Ready`" is evidence of *convergence*, not of *capability*: capability
   is what the observability, ingress, broker and storage scenarios below qualify.
   A `Ready` target whose external CA is unreachable is the expected outcome, not
   a defect to report.
3. **`PlatformUpdating` re-entry and return to Ready (rows I5–I6).** Immediately
   after `Ready` is reached and before any teardown, run a second
   `sol cloud apply <target>` carrying a platform change. The run must report
   `PlatformUpdating` — never `PlatformInstalling` — hold the elevated authority
   only for that operation, and return to `Ready` with the provisioner
   re-verified. This is the one deliberately *repeated* lifecycle transition in
   the run, and it is the live check that a privileged platform change is an
   explicit re-entry rather than a silent widening of `Ready` (invariant 3).
4. Capture the printed `deploy_kubeconfig_command` / `deploy_kube_context`
   output (INFRA-025) and actually run it — `aws eks update-kubeconfig
   --role-arn <deploy_role_arn> --alias <cluster>-deploy` — then add
   `kube_context: <cluster>-deploy` to the target. This step is itself
   qualification-relevant: does the printed instruction actually work
   end to end for a first-time reader, not just in the abstract.
5. In a **separate** session, assume the publisher role (INFRA-026),
   authenticate `docker`/`aws ecr get-login-password` as it, and push the
   qualification workload's images. This is the step that actually closes
   run 2's recorded deviation ("images were published with the operator's
   own credential").
6. `sol deploy <target> --image-ref <svc>=<repo>@sha256:<digest>` per
   service, using step 5's digests — exercises `B1`/`B2` and `C1`-`C5`
   (migration gate before workload mutation; the new namespace + RoleBinding
   bootstrap actually running as the deploy identity for the first time
   ever, not a hand-configured broad credential).
7. `B3`-`B7`: one representative transaction; a deliberately failed deploy;
   rollback to the prior release (and across a `contract` migration
   boundary, expecting a refusal); drift detection/correction.
8. `D1`-`D8`: tolerant-workload placement inspection; graceful drain;
   unplanned node loss with **measured** restoration time; drain grace;
   slow-start not liveness-killed; Kafka-worker readiness tied to
   consumer-join in both directions; a hung consumer replaced by liveness,
   not readiness; broker-unreachable-at-startup does not crash-loop.
9. `E1`-`E11`: Postgres Multi-AZ inspection (already passed live in run 2);
   **measured** infra-failure failover RTO/RPO; **measured** PITR RPO;
   **measured** restore-into-a-clean-target RTO with an application-level
   transaction proving it, not just "the provider job completed"; Kafka
   broker-loss zero-acknowledged-message-loss; **measured** consumer
   auto-resume; the qualified Kafka policy (RF≥3, `acks=all`, write caching
   off); volume-tier claim boundaries; control-state recovery from a clean
   runner (this is also the first live exercise of anything destroy-adjacent
   from INFRA-023, if the recovery procedure is exercised via a
   destroy/recreate cycle rather than only backend-object recovery);
   telemetry-loss is non-durable and does not touch the business-data claim;
   a real transaction after every recovery.
10. `F1`-`F5`: no ambient ServiceAccount token (already offline-proven,
   confirm live); credential rotation completes and the workload returns
   healthy; the old credential is rejected; zero secret values anywhere in
   the evidence bundle; and **`F5` is now a four-identity check, not
   three** — provisioner (ECR lifecycle allowed, ECR push denied,
   cluster-creator admin never standing), publisher (ECR push allowed,
   infra/IAM/repository-lifecycle denied), deploy (namespace-scoped
   application mutation allowed via `sol-deploy`, platform-namespace
   mutation denied), operator (read-only). Include one deliberate negative
   test of INFRA-025's documented residual gap: attempt to create a
   `RoleBinding` named `sol-deploy` directly inside a platform namespace via
   raw `kubectl`, authenticated as the deploy identity, bypassing `sol
   deploy`/`sol migrate` entirely. This is **expected to still succeed**
   today — SEC-005 (the admission-control closure) is intentionally
   deferred — so a success here confirms a known, already-documented gap,
   not a new defect. Record it as such; do not treat it as a Run 5 failure.
11. **Destroy lifecycle, including the failure path (rows I7–I12).** In order:
    1. `sol cloud destroy <target> --apply` on the `Ready` target: prepare →
       verify preparation → destroy → verify absence (matrix section H's
       teardown rows, section I's I7–I9, and INFRA-023's first live exercise).
       Confirm the unique per-attempt final-snapshot identity **in the actual
       RDS snapshot list**, not just the terraform argv (I8), and that **no**
       post-prepare reconciliation sets `rds_deletion_protection=true` (I7 —
       the live check for finding 15, read from the `-var` order in each
       argv).
    2. Re-run `sol cloud destroy <target> --apply` against the now-`Absent`
       target (I11): it must exit 0, report `Absent`, and prepare nothing.
    3. **The abort scenarios (I10, I12).** Re-provision, then *deliberately*
       stop the platform install partway so the target exists but its platform
       is incomplete, and run `sol cloud destroy <target> --apply`. It must
       **succeed** and enter `PreparingDestroy` — not be refused for being in
       `PlatformInstalling`. Without this, invariant 6 is unqualified, and
       invariant 6 is the one that decides whether a *failed* Run 5 can be
       cleaned up by Sol at all.
    4. Interrupt a destroy between preparation and destruction, then re-run it
       (I12): the second run completes, without reusing the first attempt's
       final-snapshot identity.
12. `G1`-`G3` only if a real receiver was set up per precondition 6;
    otherwise recorded skipped, unchanged from runs 1-2.

### Evidence must establish the identity of its own observations (HARDEN-003)

> Qualification evidence must establish both the asserted condition **and** the
> identity/provenance of the observation used to establish it. A check that cannot
> demonstrate it is observing the intended target, endpoint, process, artifact, or
> output is not qualifying evidence.

> A qualification assertion must be demonstrated capable of failing when its
> claimed condition is violated.

Both halves were learned the same way on Attempt 5, from two incidents that look
unrelated and are not. A Loki query returned nothing because a `port-forward
svc/loki` established before the `PlatformUpdating` rollout kept serving the
replaced pod — the observation targeted the wrong endpoint. An offline assertion
grepped a file the CLI never writes to — the observation targeted the wrong output
channel. Each produced something that looked authoritative and was false; the
second could not have failed at all, which is worse, because a check that cannot
fail is invisible in a green run.

In practice, for every behavioural row:

- record **what was observed and how it was reached**, including the resolved
  endpoint where a name goes through an indirection (service, proxy, load balancer,
  port-forward);
- pair any **absence** with a positive control — a canary, a known recent event, the
  endpoint's own health metric — so "nothing found" is distinguishable from
  "nothing asked";
- **re-establish connections** across anything that can replace the process behind
  a name, or pin to the thing itself rather than the thing that redirects;
- for scripted assertions, **demonstrate the failure**: feed the violated condition
  and confirm the assertion rejects it. The offline harness does this with
  `internal/ci/qualification_assertions.sh` (guarded assertions whose target cannot
  be missing) and `test_qualification_assertions.sh` (the mutation test proving they
  can fail).

### Evidence classification (unchanged framework, restated because it matters here)

1. **Static/configuration evidence** — Terraform variable defaults, RBAC
   rule text, IAM policy JSON shape. This session's offline additions
   (`cli/sol/test/check_production_infra.sh`,
   `internal/ci/test_cloud_lifecycle_offline.sh`,
   `internal/ci/test_publisher_deployer_boundary.sh`) are entirely this
   tier. Necessary, never sufficient.
2. **Mechanism/renderability evidence** — `sol cloud plan` producing correct
   Deferred/Plannable phases; `terraform validate`/`fmt` clean; an RBAC
   binding structurally namespace-scoped rather than cluster-wide; the
   lifecycle's transition/policy semantics as asserted by the unit tests and
   `internal/ci/test_cloud_lifecycle_offline.sh`. All of this is already proven
   offline. Still not sufficient for any `A`–`I` matrix row's **behavioural**
   pass condition.
3. **Real target behavioral qualification** — everything in the command
   sequence above, executed against a real disposable AWS account. This is
   the **only** tier that may mark a matrix row's Pass condition as met.
   Tiers 1 and 2 are not promoted into tier 3 anywhere in this plan or in
   its execution. This matters most for section I, where the offline harness
   proves the *mechanism* (a first install reports `PlatformInstalling`, a
   re-apply reports `PlatformUpdating`, a partially installed target is
   destructible) while only a real target proves the *authority* — that the
   privileged association is genuinely present during the phase and genuinely
   gone after it.

### Explicitly out of scope for Run 5

- `G1`-`G3` without a real alert receiver — recorded skipped, not attempted.
- SEC-005 (admission-control hardening of the deploy-bootstrap RBAC gap) —
  not a Run 5 blocker. Its residual is exactly what the `F5` negative test
  in step 10 reconfirms exists; Run 5 is not expected to close it.
- GCP or any non-AWS provider — still explicitly unqualified, fails closed
  upstream of everything in this plan.
- DEC-026's own explicit exclusions, unchanged: zone-failure tolerance,
  multi-team RBAC, admission policy, federation, signing/SBOM, automated
  volume backup.

### Qualification harness discipline

The harness may orchestrate Sol's own public commands and independently
read AWS/Kubernetes state to verify results (`aws rds describe-db-instances`,
`kubectl get`, `aws ecr describe-images`, `aws sts get-caller-identity`,
`kubectl auth can-i`, ...). It must **never** invoke `terraform` or `helm`
itself to provision or repair a phase — `internal/ci/check_public_cloud_lifecycle.sh`
already enforces this structurally for `internal/qualification/aws/live-smoke.sh`;
the Run 5 harness reusing or extending that script inherits the same guard.
Every command's exact invocation, Sol commit SHA, profile version, the verbatim
`lifecycle phase:` line per invocation, substrate
module versions, and the workload image's framework versions
(`sol-svc`/`sol-worker`/`kafka-eio`/`pg-eio`) go into the run identity
header, per the matrix's own "Run identity" table — unchanged from runs 1
and 2.

### Explicit non-execution boundary

This plan is preparation only. Executing any part of steps 1-12 requires
explicit operator authorization and presence, the same as every AWS command
in this repository's HARDEN history. Nothing above is run by writing it
down.
