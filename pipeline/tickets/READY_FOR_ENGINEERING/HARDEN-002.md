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
