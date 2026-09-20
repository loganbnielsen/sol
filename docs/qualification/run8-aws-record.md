# Run 8 record — AWS (`qual/aws/us-east-1`) — **pre-filled skeleton, not yet executed**

> **What this file is.** `docs/qualification/run-record-template.md`, pre-filled
> from the landed target (`examples/pluto/sol/qual/aws/us-east-1.yml`) and the
> procedure in `HARDEN-002` §"Exact command sequence". Structure, commands,
> assertion mapping and the measurement table are already here; the operator fills
> the **observations** and nothing else.
>
> **At execution and before merge:** rename this file to
> `docs/qualification/<YYYY-MM-DD>-run8-aws.md`, fill §1's run-time fields, and
> link it from `HARDEN-002` and
> `internal/pipeline/audits/QUALIFICATION_STATUS.md`.
>
> **Rules.** An unobserved field is `NOT REACHED` or `NOT OBSERVED` — never blank,
> never inferred from configuration or from a later command's output. Evidence is
> quoted verbatim. Each result is `PASS / FAIL / NOT REACHED / NOT OBSERVED /
> SKIPPED (reason)`; interpretation goes in the note, not the result.

---

## Preflight (2026-09-20) — **FAILED, and this is not run evidence**

Run 8 was authorized conditionally on the operator preflight passing. It did not,
so **no mutating command was issued** and nothing below §1 has been executed. Per
the authorization, this is recorded as a preflight failure rather than as run
evidence, and no attempt was made to improvise around it.

| # | Required check | Result |
|---|---|---|
| 1 | Target present, contents/hash recorded, `git status` shows only that file | **FAIL** — `examples/pluto/sol/qual/aws/us-east-1.yml` does not exist; `git status --porcelain` is empty (not even the expected `??`) |
| 2 | AWS identity/account/region are the intended disposable target | **FAIL** — no usable credentials. `[profile sol-qual]` exists in `~/.aws/config`, but its SSO token has expired and refresh is interactive (`aws sso login`). `~/.aws/credentials` is empty; `AWS_PROFILE` and `AWS_REGION` are unset |
| 3 | `TF_VAR_db_password` present | **FAIL** — absent |
| 4 | `POSTGRES_URL` present, password correctly percent-encoded | **FAIL** — absent (encoding therefore unchecked) |
| 5 | `SOL_API_KEY` present | **FAIL** — absent |
| 6 | Publisher role can push to the configured ECR registry; digests available | **NOT REACHED** — needs credentials |
| 7 | All four alert-delivery values populated, receiver live | **NOT REACHED** — needs the target |
| 8 | `sol alert test --target qual/aws/us-east-1` succeeds | **NOT RUN** — needs the target |
| 9 | Bootstrap root completed | **NOT REACHED** — needs credentials, and the bucket name is in the missing target |
| 10 | `sol cloud plan qual/aws/us-east-1` succeeds with the recorded target | **NOT RUN** — needs the target |

What *was* established, and is worth carrying forward: the identity and
`sol-qual` SSO session are configured on this host, so the run is intended to
happen here — it needs a fresh `aws sso login`, the target file, and the three
runtime inputs, in that order.

The target's absence is unexplained. It is not in the repository, not untracked,
not in a stash (`git stash list` is empty), and a search of the home directory for
its distinguishing key (`cluster_access_role_arn`) finds only `_build` copies of
`docs/qualification/run8-aws-target.example.yml`. An earlier turn of this session
ran `git stash -u` once, which stashes untracked files; no stash remains and the
commit made then contained only the record file, so the stash was popped or empty.
If the target was in the working tree at that moment, that command is the plausible
cause and this session owns it. Re-create it from the example before re-attempting.

---

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `<record at run start>` | `git rev-parse HEAD` |
| Working tree state | `<record>` | `git status --porcelain` — must show **only** the untracked qualification target, nothing else |
| Qualification target contents | `<paste, or sha256sum>` | the target is untracked, so the revision does not pin it. Start from `docs/qualification/run8-aws-target.example.yml`; the file is `examples/pluto/sol/qual/aws/us-east-1.yml` |
| Profile | `production-single-region` | target config |
| Target | `qual/aws/us-east-1` | `examples/pluto/sol/qual/aws/us-east-1.yml` |
| Account | `<observed>` | `aws sts get-caller-identity --query Account` |
| Region | `us-east-1` | target path |
| Cluster name | `sol-qual` | target config |
| Reconciliation authority | `direct` | DEC-027 selection |
| Kubernetes version observed | `<observed>` | `aws eks describe-cluster --name sol-qual --query cluster.version` |
| Operator identity running Sol | `<observed>` | `aws sts get-caller-identity` |
| `provisioner_role_arn` | `<real ARN>` | target config |
| `cluster_access_role_arn` | `<real ARN>` | target config |
| `deploy_role_arn` | `<real ARN>` | target config |
| `operator_role_arn` | `<real ARN>` | target config |
| Started (UTC) | `<record>` | `date -u +%FT%TZ` |
| Finished (UTC) | `<record>` | |
| Evidence bundle directory | `<path>` | outside the repository |

> The four ARNs above are **placeholders in the landed target** and must be the
> real ones before authorization. Record them as the run identity so a later
> reader can see which identities produced which evidence.

## 2. Entry point and environment

**Procedure followed:** `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md`
§"Exact command sequence, mapped to `docs/qualification/production-single-region-v1-matrix.md"`,
with the Run 8 contract in `docs/qualification/production-single-region-v1-matrix.md`
§"Before the next run (Run 8)".

**Working directory:** `examples/pluto` (the workspace root).
**Binary:** `dune build cli/sol/bin/main.exe` → `_build/default/cli/sol/bin/main.exe`.
**Sol's own run directories:** `~/.local/share/sol/runs/<run-id>/` (machine-local —
cite the command output, not the path, as evidence).

**Step 0 — the state backend, once, before anything else.** A Terraform root cannot
create its own backend, so the bootstrap root provisions it and the target records
the names (`docs/deployment/production-bootstrap.md` §1):

```sh
cd cli/platform/infra/bootstrap
terraform init
terraform apply -var="region=us-east-1" \
  -var="state_bucket=<globally-unique>" -var="state_lock_table=<name>"
```

Record the bucket/table names actually used, and the apply's exit status.

**Environment present at start — record the fact, not the intent:**

| Input | Required | Present? | Note |
|---|---|---|---|
| `AWS_PROFILE` | yes | | a profile that can reach the target account |
| `AWS_REGION` | `us-east-1` | | |
| `TF_VAR_db_password` | yes, from step 2 on | | the RDS master password, out of band; never committed. `sol cloud` refuses a Postgres-provisioning target without it |
| `POSTGRES_URL` | yes, for steps 6–9 | | password **percent-encoded** |
| `SOL_API_KEY` | yes, for steps 6–9 | | |
| Registry reachable by the publisher role | yes, step 5 | | `<repo>` |
| Alert route live | yes, preflight guarantee | | `sol alert test --target qual/aws/us-east-1` → `<result>` |

> The target is the operator's own untracked file, started from
> `docs/qualification/run8-aws-target.example.yml`. Record the real account, ARNs,
> registry, domain, CIDR, state bucket and alert endpoint here **and** attach the
> target's contents (§1): a value that reached AWS but is not in this record is a
> run identity that cannot be reproduced.

## 3. Step log

Each step pre-listed with its command and the rows it carries. Fill **Observed**,
**Result** and the evidence pointer.

### Step 1 — plan, before any mutation

- **Command:** `<sol> cloud plan qual/aws/us-east-1`
- **Assertion:** matrix §A target-capability preflight; no mutation on a plan.
- **Observed** (verbatim phase lines, deferred vs plannable):

  ```text
  ```

- **Result:** `<PASS | FAIL | …>` **Evidence:** `<log>`

### Step 2 — apply through `Ready`

- **Command:** `<sol> cloud apply qual/aws/us-east-1`
- **Assertions:** matrix rows **I1–I4** captured from this step; §A preflight;
  §I lifecycle phases. I1 `CloudBootstrap` before any platform mutation; I2 the
  privileged installation authority still in place after chart RBAC and the
  `sol-deploy` ClusterRole exist; I3 `Ready` only after that authority is revoked
  and the **bounded** provisioner is verified (positive **and** negative `can-i`);
  I4 `rds_deletion_protection = true` in force while `Ready`.
- **Observed** (phase lines verbatim, bootstrap window open/close times, `can-i`
  results with the identity that produced each):

  ```text
  ```

- **Result:** `<…>` **Evidence:** `<log>`

### Step 3 — `PlatformUpdating` re-entry and return to `Ready`

- **Command:** `<sol> cloud apply qual/aws/us-east-1` carrying a platform change
- **Assertions:** rows **I5–I6**. Must report `PlatformUpdating`, never
  `PlatformInstalling`; elevated authority only for that operation; returns to
  `Ready` with the provisioner re-verified.
- **Observed:**

  ```text
  ```

- **Result:** `<…>` **Evidence:** `<log>`

### Step 4 — the printed deploy kubeconfig instruction, actually run

- **Command:** `aws eks update-kubeconfig --role-arn <deploy_role_arn> --alias sol-qual-deploy`
  (verbatim from Sol's `deploy_kubeconfig_command` output), then add
  `kube_context: sol-qual-deploy` to the target.
- **Assertion:** INFRA-025 — the printed instruction works for a first-time reader.
- **Observed:**

  ```text
  ```

- **Result:** `<…>` **Evidence:** `<log>`

### Step 5 — publish the workload images as the publisher role

- **Commands:** assume the publisher role; `aws ecr get-login-password`; push.
- **Assertion:** INFRA-026 — images are published by the publisher identity, not
  the operator's own credential (Run 2's recorded deviation).
- **Observed** (digests):

  ```text
  ```

- **Result:** `<…>` **Evidence:** `<log>`

### Step 6 — `sol deploy`, per service

- **Command:** `<sol> deploy qual/aws/us-east-1 --image-ref <svc>=<repo>@sha256:<digest>`
- **Assertions:** §B B1/B2, §C C1–C5 — the migration gate runs **before** any
  workload mutation, and the namespace + RoleBinding bootstrap runs as the deploy
  identity for the first time.
- **Observed** (the gate's output; if it fails, the
  `migration-status Job evidence` block verbatim — that block is the INFRA-040
  change and is the whole point of having it):

  ```text
  ```

- **Result:** `<…>` **Evidence:** `<log>`

### Step 7 — §B B3–B7

- One representative transaction; a deliberately failed deploy; rollback to the
  prior release (and across a `contract` migration boundary, expecting a refusal);
  drift detection/correction.
- **Observed:** `<per scenario>`
- **Result per scenario:** `<…>`

### Step 8 — §D D1–D8

- Placement inspection; graceful drain; **unplanned node loss with measured
  restoration time**; drain grace; slow-start not liveness-killed; Kafka-worker
  readiness tied to consumer-join in both directions; hung consumer replaced by
  liveness; broker-unreachable-at-startup does not crash-loop.
- **Observed:** `<per scenario>`
- **Result per scenario:** `<…>`

### Step 9 — §E E1–E11

- Postgres Multi-AZ inspection; **measured** infra-failure failover RTO/RPO;
  **measured** PITR RPO; **measured** restore-into-a-clean-target RTO with an
  application-level transaction proving it; Kafka broker-loss zero-acknowledged
  message loss; **measured** consumer auto-resume; the qualified Kafka policy.
- **Observed:** `<per scenario>`
- **Result per scenario:** `<…>`

### Step 10 — read-only networking inspection (INFRA-036)

- Record the node security group's effective ingress rules and whether the control
  plane reaches a node's kubelet. **Change nothing.** The question and the two
  admissible conclusions are in `HARDEN-002` §"Read-only networking inspection".
- **Observed:**

  ```text
  ```

- **Result:** `<…>` **Evidence:** `<log>`

## 4. Row roll-up

| Row | Required evidence class | Result | Evidence reference |
|---|---|---|---|
| A target-capability preflight | `BEHAVIORAL` | | |
| B1–B7 deploy / pointer / rollback | `BEHAVIORAL` | | |
| C1–C5 migration ordering | `BEHAVIORAL` | | |
| D1–D8 availability | `BEHAVIORAL` | | |
| E1–E11 durability | `BEHAVIORAL` | | |
| F security posture | `BEHAVIORAL` | | |
| G alerting | `BEHAVIORAL` | | |
| H1–H6 evidence-bundle integrity | `BEHAVIORAL` | | |
| I1–I6 lifecycle phases | `BEHAVIORAL` | | |
| I7–I14 | `BEHAVIORAL` / `MECHANISM` | | |

The authoritative per-row list is
`docs/qualification/production-single-region-v1-matrix.md`; rows this run does not
touch are listed once under §9 as `NOT REACHED` with the reason.

## 5. Run 8 assertions (from the matrix §"Before the next run")

### 5.1 The absence checks fire

**Approved plan (2026-09-20):** deliberately plant one tagged residual per class —
one EIP, one NAT gateway, one EBS volume tagged as the target's — **before** the
final destroy, and treat the first failed absence verification as an **expected
assertion result**, not a failed run. Capture that it detects the planted
resources, then remove them and require the normal destroy/verification path to
reach `Absent`.

- **How the residual was planted (command, tags, time):**

  ```text
  ```

- **First `verify_aws_destroy` run — expected `FAIL`.** Verbatim output naming each
  class:

  ```text
  ```

- **Result:** `<PASS if it detected all three; FAIL if any class was not detected>`
- **Residual removed (command, time):** `<…>`
- **Second destroy/verification — required `Absent`.** Verbatim output:

  ```text
  ```

- **Result:** `<PASS | FAIL>`

> A class the verifier fails to detect is a **finding**, not a rerun: record which
> class, the exact filter used, and what the account actually held. This is the
> half HARDEN-003 exists for — without it the run only proves the verifier accepts
> a clean account.

### 5.2 Steady-state authority, as the named identity

- **Identity used:** `<cluster_access_role_arn principal>`
- **Command attempted (expected denied):** `aws eks associate-access-policy …`

  ```text
  ```

- **`can-i` positives and negatives, each with the identity that produced it:**

  | Check | Identity | Result |
  |---|---|---|
  | `escalate clusterroles` | | |
  | `bind clusterroles` | | |
  | steady-state operation | | |

- **Result:** `<PASS | FAIL>`

### 5.3 Migration gate, end to end

- Covered by step 6; state here whether the gate ran before any workload mutation
  and whether its failure path (if any) produced the evidence block.
- **Result:** `<PASS | FAIL | NOT REACHED>`

## 6. Measurements (only what was measured)

| Target | Required bound | Measured | Method | Within bound? |
|---|---|---|---|---|
| Node-loss restoration, required ready capacity | ≤ 300 s | | | |
| Postgres failover RTO | ≤ 120 s | | | |
| Postgres failover RPO | ≈ 0 | | | |
| Postgres logical-loss RPO (PITR) | ≤ 300 s | | | |
| Postgres restore RTO into a clean target | ≤ 3600 s | | | |
| Kafka acknowledged-message loss on one broker | 0 | | | |
| Kafka consumer auto-resume | ≤ 60 s | | | |

## 7. Deviations

| Time | Step | Done differently | Why | Authorized by | Effect on evidence |
|---|---|---|---|---|---|
| | | | | | |

## 8. Cleanup and final state

- **Destroy command and time:** `<sol> cloud destroy qual/aws/us-east-1 --apply`;
  exit status `<record>`
- **`retention:` in force:** `none` (from the target config)
- **Provider-side absence checks:** each command + verbatim result

  ```text
  ```

- **Manual steps required:** `none` / list
- **Resources left behind:** `none` / list with why

## 9. What this run does not establish

- Rows not reached (list with the reason).
- The two TypeScript services are omitted in this target; TypeScript parity is not
  exercised (DEC-026 §2), and that is a profile limitation, not a run result.
- External ACME/TLS issuance is not a `Ready` gate; if it is not exercised, record
  it as skipped rather than passed.

## 10. Ledger and findings updates implied

Proposed, not applied — the qualification lead applies them, citing this record's
run identity.

| Finding / row | State before | Would move to | Because (evidence reference) |
|---|---|---|---|
| FND-0002 (denied steady-state identity) | `FIXED_UNQUALIFIED` | | §5.2 |
| FND-0003 (absence half / effective authority) | `OPEN` | | §5.1, §5.2 |
| FND-0006 (retention → `Absent`) | `QUALIFIED` (Run 7) | | §8 |
| FND-0008 (deploy path) | `QUALIFIED` (Run 7) | | §3 step 6 |
| Matrix §B, §D | `NOT RUN` | | §3 steps 7–8 |
