# AWS qualification run procedure (written for Run 5; used by Runs 5–7)

> Moved verbatim on 2026-09-24 from `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md` (lines 1002–1357 at `a9d7d827`), when the HARDEN-002 epic was closed as a ticket and its run history moved into the qualification ledger. Headings keep their original levels; the text is unchanged. Index: `internal/qualification/README.md`.

## Run 9 — authorization → execute (prepared 2026-10-03)

**Status: preparation only.** Nothing in this section has run. It is the operational
package that makes the run executable as soon as the operator authorizes it
(`ALPHA_CAMPAIGN.md` §7.1–§7.3) and `VERIF-027` has produced the reference application. It
binds the AWS matrix rows to the alpha acceptance rows, the identities, the resources, the
evidence commands, the failure injections and the teardown. Where the Run 5 text below
disagrees, this section is authoritative for Run 9.

### What Run 9 changes from Run 8

| Change | Why | Owner |
|---|---|---|
| The workload is the alpha reference application (`ALPHA_CAMPAIGN.md` §2) | the campaign qualifies the frozen contract, not the pre-campaign `charge_svc`/`notify_worker` pair | `FEAT-131`/`FEAT-132`; `HARDEN-007` drives it |
| B3's `-svc` half runs through the qualification transport | no production identity can reach a private `ClusterIP`, and that is deliberate (DEC-039) | `INFRA-060`; `live-row.sh transport` |
| The harness runs the released bundle, which pins its own migration runner by digest | the run qualifies the artifact a user installs (J3); Sol publishes nothing and a release uses only its own assets | `RELEASE-006` (landed, part A) |
| `VERIF-021` / `VERIF-022` collect in this target | shared substrate rather than a disconnected secret-only experiment | `VERIF-021`, `VERIF-022` |
| Five production identities, not four | the DEC-034 provisioning / steady-state split | this section |

### The five production identities, corrected

Run 5's precondition 3 names **four** IAM roles (provisioner, publisher, deploy, operator).
The bootstrap root emits **five** policy documents and the Run 8 target declares **five**
identities; `cluster_access_policy_json` / `aws.cluster_access_role_arn` — the DEC-034 split
between cloud-substrate mutation and steady-state platform management — is the one Run 5
omitted. Run 9's precondition is:

| Identity | Bootstrap output | Target field | Owns |
|---|---|---|---|
| provisioner | `provisioner_policy_json` | `aws.provisioner_role_arn` | cloud substrate mutation; access-entry / policy association |
| cluster-access | `cluster_access_policy_json` | `aws.cluster_access_role_arn` | steady-state platform management |
| deploy | `deploy_policy_json` | `aws.deploy_role_arn` | application / release mutation, namespace-scoped |
| operator | `operator_policy_json` | `aws.operator_role_arn` | read-only diagnostics |
| publisher | `publisher_policy_json` | — (never a target field) | ECR push only, on its own assume-role session |

The qualification transport principal is a **sixth** identity, created by the harness for the
transport only (`internal/qualification/transport/`), never named by a target field
(DEC-039 §3). Run 5's step 10 "four-identity check" is read as five for Run 9.

### Alpha row reconciliation (the run's scope)

The workload is the frozen reference scenario, implemented by `FEAT-131`/`FEAT-132` in the
OCaml namespace; the TypeScript namespace is not in the production profile (DEC-026 §2).
The harness binds the scenario through `SVC_UNIT`/`WORKER_UNIT` (with their directories
`SVC_DIR`/`WORKER_DIR`), `APP_NS`/`WORKER_NS`, `APP_SERVICE`, `APP_PORT` and `SCENARIO`. The
pre-campaign shape is the default (`charge_svc`/`notify_worker`, `charges`); the alpha binding
is `SVC_UNIT=orders_svc WORKER_UNIT=fulfilment_worker APP_SERVICE=orders-svc SCENARIO=orders`
(with `SVC_DIR=payments`, `WORKER_DIR=comms`, `APP_NS=pluto-payments`, `WORKER_NS=pluto-comms`
unless `FEAT-131`/`FEAT-132` land different names — then the binding values change, not the
mechanism). The alpha rows whose target includes `aws`, and the AWS matrix rows that carry them:

| Alpha row | Capability | AWS matrix row(s) | Run 9 |
|---|---|---|---|
| B1 | Service accepts a request | B3 | in scope |
| B3 | Outbox relay | B3 | in scope |
| B4 | Worker consumes and mutates | B3 | in scope |
| C1 | Migrations apply | C1 | already `PASS (LIVE, Run 7)`; re-confirm |
| C2 | Deploy migration gate | C1–C5 | in scope (LIVE completion) |
| C3 | Per-migration checksum | C2, C5 | in scope (LIVE) |
| C4 | Postgres durability (AWS) | E1–E4 | in scope |
| C5 | Durable leased jobs | FEAT-077 rows | in scope (LIVE) |
| C6 | Transactional outbox | E11 | in scope (LIVE) |
| D1 | Topic provisioning | FEAT-117 rows | in scope (LIVE) |
| D4 | Retry/DLQ topology | FEAT-076/078/118 rows | in scope (LIVE) |
| D5 | Decode-error DLQ | OB-F2 | in scope (LIVE) |
| D7 | Broker durability (AWS) | E7 | in scope |
| D8 | Broker loss + resume | E5, E6 | in scope |
| E2 | Production SASL_SSL | FEAT-093 row | in scope (LIVE) |
| E4 | Managed secret projection | — | in scope (`VERIF-021`) |
| E5 | Projected SA tokens | — | **blocked**: `FEAT-134` (implementation) then `VERIF-022` |
| E6 | Workload cloud authority | I3, F5 | in scope (DEC-062 / `VERIF-021`) |
| E7 | Scoped identities | I2, I3, I6, F5 | in scope (LIVE completion) |
| E8 | No ambient token / no leaked secret | F1, F4 | in scope |
| F1 | Profile preflight | A1–A12 | already `PASS (LIVE, Run 7)`; re-confirm |
| F2 | Provision + normal deploy | B1 | in scope (the profile row is the one Run 8 did not claim) |
| F3 | Idempotent re-deploy | B2 | in scope |
| F4 | Failed deploy + rollback | B4–B6 | in scope |
| F5 | Drift detection | B7 | in scope |
| F6 | Immutable artifacts | DEC-026 §6, SEC-011 | in scope (registry digest verification) |
| F7 | Release provenance | FEAT-110, DEC-057 §9 | in scope (LIVE completion) |
| F8 | Observed → desired contract | FEAT-130 | in scope (LIVE) |
| H1 | Bad-message / DLQ | OB-F2 | in scope (LIVE) |
| H3 | Deploy → fail → diagnose → rollback → recover | B | in scope |
| H4 | Availability | D1–D8 | in scope |
| H5 | Broker loss | E5, E6 | in scope |
| H6 | Postgres failure / restore | E2–E4, E11 | in scope |
| H7 | Telemetry loss | E10 | in scope |
| I1 | Installation | AWS Run 7 | already `PASS (LIVE)`; prerequisite |
| I2 | Environment to `Ready` | I1–I6 | already `PASS (LIVE)`; re-confirm |
| I3 | Ready-state destroy | I9, H6 | in scope (AWS `NOT RUN`) |
| I4 | Destroy from partial / failed install | I10 | in scope (AWS) |
| I5 | Destroy idempotence | I11 | in scope |
| I6 | Retention | I8 | already `PASS (LIVE, Run 7)` |
| I7 | Uninstall | DEC-057 §7 | in scope |
| I8 | Independent absence verification | H6, DEC-045 | in scope (LIVE completion) |
| — | Delivered-and-acknowledged alert (AWS matrix G1–G3) | G1–G3 | **BLOCKED**: a real receiver and an owner who acknowledges |

Rows the run does not reach stay `NOT RUN` in the record; they are not inferred from a later
command's output.

### Prerequisites (all present before any billable resource is created)

**Environment**

1. A fresh, disposable, isolated AWS account and an unexpired SSO session for the operator's
   profile (`aws sts get-caller-identity` names the qualification account).
2. `aws`, `terraform` ≥ 1.5, `kubectl`, `dig`, `jq`, `python3`; `docker` reachable from the
   shell that runs the app phase (`docker version` succeeds, or run under `sg docker -c`).
   `opam` + `dune` are needed only if the runner is built from source rather than taken from
   the release.
3. The **released bundle** (`RELEASE-006`): `sol-<version>-linux-x86_64.tar.gz` extracted,
   `SOL_HOME` unset, `sol --version` reports the tag, `sol assets` reports every asset
   present. `SOL=<bundle>/bin/sol` selects it for the harness.
4. Runtime inputs, never in the repository: `TF_VAR_db_password` (≥ 8 characters, no `/`,
   `@`, `"`), `SOL_API_KEY`, and `POSTGRES_URL` with the password percent-encoded. The
   harness reads `POSTGRES_URL` from the cluster root's own `postgres_url` output.
5. The durable bootstrap root applied: the state bucket and lock table, and the delegated
   `qual-aws.sol-fab.dev` zone with `manage_dns_zone=true`. The zone is durable and outlives
   the target.
6. The five IAM roles created by the operator from that root's generated policy documents
   (`terraform output -raw <name>_policy_json`), each used on its own session — the publisher
   on a session used by nothing else. Sol owns the policy contracts, never the role
   lifecycle.
7. The qualification transport role (a name the harness is given, never a target field).
8. A target file `examples/pluto/sol/environments.local.yml` copied from
   `run8-aws-target.example.yml` with real values. It is untracked by design, so the record
   carries its contents or a hash plus its path. It declares `profile: production-single-region`,
   the five role ARNs, `kube_context`, the registry, `cluster_endpoint_cidr` (never
   `0.0.0.0/0`), `node_failure_headroom_nodes`, `destroy_retention: none`, and the two
   TypeScript units omitted. The alert fields are required by the profile preflight; they are
   set to a real receiver only when pursuing G1–G3, and the run records G as blocked otherwise.
9. Operator authorization for the live run (`ALPHA_CAMPAIGN.md` §7.1–§7.3) and the release
   version (§7.6).

### Expected resources and cost-bearing steps

Billable from `sol cloud apply` until the independent inventory is `ABSENT`; the cost rule is
absolute (tear down before asking). The target creates, at least:

| Resource class | Declared by | Teardown class |
|---|---|---|
| EKS cluster + control plane | cluster root (`kubernetes_version` 1.36) | cluster |
| Managed node group, 4 × `m6i.xlarge` desired | cluster root | cluster |
| RDS PostgreSQL Multi-AZ, `db.t4g.small`, engine 16.15 | cluster root | database (plus its snapshots) |
| VPC, subnets, route tables, one NAT gateway + EIPs | cluster root | network |
| EBS volumes (PVCs, node root disks) | storage class / PVCs | storage |
| Application/ingress load balancer | platform (ingress) | load balancer |
| ECR repositories | cluster/platform root + the runner repository the harness creates | registry (empty after teardown) |
| CloudWatch log groups | platform | logs |
| Route 53 `qual-aws.sol-fab.dev` | durable bootstrap root | **retained** (durable, not a target resource) |

The nodes dominate the hourly cost; the run's own gate is the operator's authorization, and
the destroy is part of the run, not a follow-up. A run that stops early is still destroyed.

### The run, phase by phase

`internal/qualification/aws/live-row.sh <phase>` orchestrates Sol's public commands and reads
provider/Kubernetes state independently. It never invokes `terraform` or `helm` for a target
phase: `cloud` reconciles the *durable* bootstrap root (the operator's prerequisite) with
`terraform`, and every disposable-target step goes through Sol. `SOL` selects the released
bundle.

**`cloud`** — reconcile the durable root; `sol cloud plan <target> --var-file <tfvars>`;
`sol cloud apply <target> --var-file <tfvars>` (the row's `qual-aws-row.tfvars`); build the
deploy/access/operator kubeconfigs; capture nodes and the cluster root state. The profile emits
its `-var` arguments after the var file, so the profile still wins on every variable it sets.
Evidence: `bootstrap.log`, `cloud-plan.log`, `cloud-apply.log`, `k8s-nodes.txt`,
`state/cloud.tfstate`, and the verbatim `lifecycle phase:` line per invocation. Rows: I1, I2,
I4, A, F1, F2.

**`transport`** — probe the production identities for `pods/portforward` (must answer `no`),
establish the qualification transport
(`internal/qualification/transport/establish.sh <cluster> <qualifier-role> <region> <namespace>`),
record the qualifier's own `auth whoami` session, probe the production identities again, and
confirm the qualifier can open the transport. Evidence:
`transport-separation-pre.txt`, `transport-establish.log`, `transport-whoami.json`,
`transport-separation-post.txt`. Rows: E7, INFRA-060 criterion 5, DEC-039 §4. The record names
the transport identity separately from the identities under qualification, and shows none of
the latter holds `pods/portforward` before or after.

**`app`** — the publisher's work, then Sol's: build and push the workload images, publish the
migration runner (below), set the runtime secrets, `sol migrate apply <target>`,
`sol deploy <target> --registry <registry> --image-tag <tag>`, then drive the representative
transaction through the transport (`transport-transaction.sh`, port-forward to the private
`ClusterIP`). Evidence: `app-transaction.log`, `transport-port-forward.log`,
`transport-transaction.txt`, `k8s-pods.txt`, `state/cloud.tfstate`. Rows: B1, B3, B4, C1–C6,
D1, D4, D5, F2, F6–F8. The read-back is the application's own effect — the worker's row
visible to the service — never broker progress (DEC-039 §5).

**`destroy`** — capture both roots' state with `terraform state pull` into the bundle, run
`sol cloud destroy <target> --apply`, then the independent inventory. **`verify`** runs the
inventory alone. Rows: I3, I5, I7–I9, H6.

### VERIF-021 — managed secret projection and the fenced grant (alpha E4, E6)

This is a live cell of DEC-029's driver × runtime table, run inside the target so the
substrate is shared. The CSI driver and the AWS provider are **not** Sol platform components
(`docs/deployment/compatibility.md` records them as candidates); the run installs them out of
band, as `VERIF-020` did for Vault, and records the chart and provider versions.

1. Reconcile the declared secret grant with `sol grants plan <target>` / `apply <target>`
   (DEC-062, `FEAT-127`), so the unit has a real fenced identity.
2. Create a `SecretProviderClass` with `provider: aws` for a Secrets Manager secret under the
   environment's path, and confirm the provider authenticates as the **pod's** identity
   (IRSA / EKS Pod Identity), never the node's.
3. A granted unit reads the value; remove the unit's grant and confirm the read is
   `AccessDenied` while a granted read still succeeds.
4. `enableSecretRotation` updates the mounted file within the stated bound; measure the
   rotation-to-file-change delay. A new pod fails closed while the authority is unavailable;
   a running pod keeps its last-known value.
5. DEC-062 rule 6: run `aws iam simulate-principal-policy` against the unit's role for an
   allowed and a denied action, including a permissions boundary, and compare with a real
   call. Record on `DEC-062` whether the simulation reflects boundaries, resource policies
   and SCPs; if it does not, the deploy-time verification (`FEAT-128`) needs a mechanism that
   does.

Evidence: the exact commands and outputs, the provider/CSI versions, the measured delay, and
the DEC-029 cell verdicts.

### VERIF-022 — projected ServiceAccount tokens (alpha E5) — blocked on implementation

`VERIF-022` qualifies the DEC-063 mechanism: a projected ServiceAccount token volume with
`audience: <callee unit>` and `expirationSeconds: 3600`; no Kubernetes API access; issuer
discovery; caller/`calls`-graph authorization (`401`/`403`/wrong-`aud`); key rotation; and
refresh without restart.

**It cannot be collected in Run 9 today, and the blocker is implementation, not
authorization.** The callee-side generic JWT verification exists
(`framework/ocaml/sol-svc/lib/auth.ml`, `Jwks_url` + JWKS fetching), but DEC-063's mechanism
is absent from the tree: no Kubernetes `serviceAccountToken` projected volume is rendered
(`rg -n 'serviceAccountToken|expirationSeconds' cli/ framework/` finds no projected volume;
the manifest builder only sets `automountServiceAccountToken: false`), and the caller API
`Service.call` and the `calls`-graph authorization do not exist (`rg -n 'Service\.call'
framework/ cli/` finds nothing). `FEAT-134` implements DEC-063's already-decided API; the
pluto `calls` edge it updates is `payments/charge_svc` → `checkout/checkout_svc`. Until that
lands, E5 is `BLOCKED` — recorded as blocked, never weakened.

### Failure injections (each is a scenario, not an accident)

| Row | Injection | Observable |
|---|---|---|
| B4 | deploy a workload that cannot become ready (bad probe/image) | deploy exits non-zero; the prior release stays authoritative; pods unchanged |
| B6 | roll back across a `contract` migration | refused, naming the migration boundary; pointer unchanged |
| C2 | add a migration file without applying it, then deploy | deploy fails closed naming the missing migration; no workload mutated |
| C3 | edit an applied migration, then `sol migrate status` / deploy | the checksum mismatch is reported |
| D5, H1 | produce an undecodable record to the worker's topic | structured decode log, `sol_worker_decode_errors_total`, a DLQ record on `<topic>.<group>.dlq` with the raw bytes, and the source offset advancing |
| H2 | make the broker unreachable, then restore it | the relay holds; recovery publishes; a relay restart preserves `ord` order |
| H4/D3 | terminate a node's EC2 instance with no drain | measured time from `NotReady` to required ready capacity restored; PASS iff ≤ 300 s |
| H5/E5/E6 | produce N `acks=all` messages, kill one broker | none lost; measured consumer auto-resume ≤ 60 s |
| H6/E2–E4 | `aws rds reboot-db-instance --force-failover`; PITR restore into a clean target | measured RTO/RPO within the matrix bounds; the app serves a transaction after each |
| H7/E10 | stop the telemetry backend | the app is unaffected; the telemetry gap is recorded, with no business-data claim |
| I10 | stop the platform install partway, then `sol cloud destroy --apply` | the destroy succeeds and enters `PreparingDestroy`; no out-of-band deletion |
| I12 | interrupt a destroy between preparation and destruction, then re-run | the second run completes without reusing the first attempt's snapshot identity |

### Teardown and independent absence verification

1. `terraform state pull` for both the cluster and platform roots into the evidence bundle
   **before** any teardown (ledger rule 4).
2. `sol cloud destroy <target> --apply`; capture every `lifecycle phase:` line and the
   terraform argv (I7's `-var` order, I8's targeted preparation, I9's `Destroying` → `Absent`).
3. Independent inventory, tri-state `PRESENT` / `ABSENT` / `UNKNOWN`, over EKS clusters, RDS
   instances and snapshots, EC2 instances, VPCs, NAT gateways, EIPs, EBS volumes, ELBv2 load
   balancers, ECR repositories and CloudWatch log groups. A failed or unreadable read is
   `UNKNOWN`, never absence. The matrix's H6 classes are the set; the matrix's "assertions that
   ride along" requires the absence checks to have been seen to fail against a real residual.
4. Confirm the durable Route 53 zone and its nameservers are unchanged, and that no snapshot,
   bucket, address or volume is retained (`retention: none`).
5. Re-run `sol cloud destroy <target> --apply` against the now-`Absent` target: exit 0,
   `Absent`, no preparation (I11).

### Released-bundle interface (RELEASE-006, landed)

`RELEASE-006` part A moved the AWS and GCP harnesses onto the installed bundle and pinned it
with a harness test. Run 9 uses that interface: `SOL_INSTALL` is the extracted prefix,
`SOL_HOME` is unset, `sol --version` equals the bundle version, the released platform bundle
lives under `share/sol/<version>/platform`, and the bundle's
`share/sol/<version>/migration-runner-image` pins the migration runner **by digest**. The
harness does not publish a runner and hands Sol no runner reference; an installed Sol refuses
`SOL_MIGRATION_RUNNER_IMAGE` because a release uses only its own assets (DEC-049). The harness
records the bundle version and that digest in `sol-identity.txt`. Run 9 does not start against a
checkout build: the artifact a user installs is the thing under qualification (J3).

### What Run 9 does not establish

- The delivered-and-acknowledged alert (AWS matrix G1–G3) without a real receiver and an owner.
- Alpha E5 (`VERIF-022`) until `FEAT-134` lands, and the DEC-063 mechanism on `gcp`/`byo`.
- The TypeScript production profile (DEC-026 §2), GCP, `byo`, `self_hosted_durable` /
  `external` observability, zone-failure tolerance, multi-team RBAC, admission policy,
  federation, and signing/SBOM (the matrix's section J).
- Any row it does not reach: those stay `NOT RUN` with the reason, never promoted.

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
2. `platform/cloud/aws/bootstrap` applied: state bucket + lock table.
3. **Four** IAM roles created by the operator (not Sol — AUDIT-072/INFRA-026:
   Sol owns the policy contracts, never role lifecycle) from the bootstrap
   root's four generated documents: `provisioner_policy_json`,
   `publisher_policy_json` (new since run 2), `deploy_policy_json`,
   `operator_policy_json`. The publisher role needs its own assume-role
   session, used by nothing else — reusing the provisioner's or deploy's
   session to publish would silently re-introduce the identity conflation
   INFRA-024/INFRA-026 exist to prevent.

   > **Corrected for Run 9 (2026-10-03).** The bootstrap root emits **five** policy
   > documents, not four: `cluster_access_policy_json` (the DEC-034 steady-state
   > identity) was omitted here. See § *Run 9 — the five production identities,
   > corrected* above, which is authoritative for Run 9.
4. Target file declaring: `profile: production-single-region`, region,
   `aws.provisioner_role_arn`, `aws.deploy_role_arn`, `aws.operator_role_arn`, a
   `cluster_endpoint_cidr` that is not `0.0.0.0/0`, `state_bucket` /
   `aws.state_lock_table`. Alert receiver fields only if pursuing `G1-G3`.
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

### Qualification transport into private application services (INFRA-060 / DEC-039 / FND-0020)

B3 drives a transaction at an application's **private** `ClusterIP` service, and no
identity Sol provisions can reach one — deliberately (DEC-038 §4, DEC-039 §1). What was
missing was the procedure's own assumption: B3 did not say how the harness obtains
connectivity. This is where.

**The transport is a qualification-only capability, established out of band before B3.**
It lives in `internal/qualification/transport/`: the group `sol:qualifiers`, granting
`pods`/`services` `get`/`list` and `pods/portforward` `create`, and nothing else. It is
never applied by `sol cloud apply`, no production Terraform root references it, and no
target field names the principal; `internal/ci/check_qualification_transport.py` and its
mutation test hold both directions.

```
internal/qualification/transport/establish.sh <cluster> <qualifier-role> <region> <application-namespace>
```

Establishment opens a temporary cluster-admin window on the qualifier's own principal to
write the cluster-scoped RBAC, then closes it by **deleting the access entry and recreating
it narrow** — never by disassociating the policy, which was measured live to be reported
complete while the authorizer still granted cluster-admin (`FND-0021` / `INFRA-061`). It
then verifies the **effective surface** with real calls as the principal `kubectl auth
whoami` names: the session is that principal's assumed role and the group is
`sol:qualifiers`; `get pods` succeeds and `list services` is permitted; `create
pods/portforward` is permitted; `get secrets` is denied by a real call; and `auth can-i`
answers `no` for `*/*`, `create pods/exec`, `get pods/log` and `delete pods`. When a check
fails it removes the entry rather than leave a credential it could not show to be
transport-only, and it reports that removal only after the entry is confirmed gone — if it
cannot remove the entry it names the principal and prints the command to remove it by hand.
The AWS side is checked before the window opens at all: the role's trust must name this
account's root and nothing else, and it must carry no attached policy beside the script's own
`eks:DescribeCluster`-on-the-cluster inline policy. A run does not proceed on an establishment
that did not report that verification.

**The identity split is mandatory (DEC-039 §4).** The record names the identity that
established and drove transport **separately** from the identities whose contracts are
under qualification. Transport is harness mechanics: what it carries is evidence about the
application, and the fact that a qualifier could reach the service is never evidence about
provisioner, publisher, deploy or operator. This run's own claim about those identities is
the unchanged one — none of them holds `pods/portforward` — and the record shows it, before
and after the transport existed.

Re-establish the connection across anything that can replace the process behind a name: a
port-forward opened before a `PlatformUpdating` rollout kept serving the replaced pod once
already (Attempt 5), so the record names the resolved endpoint each read actually came from
(HARDEN-003, *Evidence must establish the identity of its own observations*).

### Re-establishing a workload fixture (INFRA-062 / FND-0022, decided 2026-10-03)

A run that has recorded a fixture failure needs a way to start again from the same
artefact. Redeploying the revision Sol already recorded does **not** do it, and that is
product behaviour, not a defect: an unchanged Deployment spec means no rollout, so the
deploy reports success and advances the release record while the same pods, with the same
creation timestamps, stay failing in place. B2 qualifies exactly that idempotence — an
identical repeat deploy restarts nothing — so the reset must not be obtained by weakening
it.

**The reset is a teardown and recreate of the target, driven through Sol's own surface,
not a hand-repair.**

1. **Freeze the failing epoch's evidence first**, because the teardown destroys it.
   Before any teardown command runs, the record must carry the verbatim `sol status`
   verdict and pod table (names, restart counts, creation timestamps), the readiness
   probe failure it reported, the consumer group's independent view from the broker, and
   the release record in force.
   `internal/qualification/records/2026-09-20-run8-aws.md` is the model: it declares an
   explicit evidence boundary, and nothing on one side of it supports a claim about the
   other.
2. **Tear down** with `sol cloud destroy <target> --apply`, the same documented path as
   step 11, and wait for verified `Absent`. A namespace-scoped teardown is deliberately
   not used: no qualification identity holds a mutating verb in an application namespace
   (DEC-039's transport grant is `pods`/`services` `get`/`list` and `pods/portforward`
   `create`, nothing else), and the provisioner — the identity that owns infrastructure
   mutation — mutates only through Sol's lifecycle. A `kubectl delete pod` or
   `kubectl delete namespace` would be an out-of-band mutation that leaves Sol's recorded
   state describing objects that no longer exist, and it hides the missing capability
   rather than recording it.
3. **Recreate through this procedure**, from step 1, with the **same workload artefact**:
   the same `--image-ref <svc>=<repo>@sha256:<digest>` values recorded for the failing
   epoch, at the same profile, region and scale. A new digest is a new revision — it
   resets the pods but changes what is under test, so the recreated epoch would not be
   comparable to the one that recorded the failure. That comparison is the whole point of
   the reset, and it is why the new revision was rejected as the mechanism.
4. **Declare the new epoch.** It begins when the recreated target has reached `Ready` and
   the workload has been redeployed from the same digests; the record names the boundary,
   the digests, and the recreated target's own release record. The reset's effect on
   release identity is: the destroyed target's release record does not survive, so the
   two epochs are compared by **artefact** (the digests), not by release identity. Nothing
   observed before the boundary may support a claim about the recreated fixture, and
   nothing observed after it may be used to support the failure finding.
5. **Re-establish what the new epoch relies on, and say what it does not.** Evidence
   scoped to the destroyed target instance — the cloud and platform rows, section I — is
   that instance's and is cited as such; the recreated epoch re-establishes the rows its
   own claims depend on. A row the recreated instance did not exercise is `NOT REACHED`
   for the new epoch, not inherited from the old one.

**The reset is not a repair of a finding.** If the fixture failed because of a defect
under qualification, record the finding before the teardown, because the teardown destroys
the failing state. A fixture that fails again in the recreated epoch is a finding about the
target, not a reason for a second reset inside the same epoch.

**What this does not create.** Sol gains no restart or rollout operation: that remains a
separate, undecided product question (FND-0022), and no row here needs it. The harness also
never invokes `terraform` or `helm` itself; the teardown and the recreate are Sol's own
commands.

### Exact command sequence, mapped to `internal/qualification/aws/production-single-region-v1-matrix.md`
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
   `cli/` (`sol logs`, port-forward, exec).

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
   own credential"). Do **not** publish a migration runner: Sol runs the
   installed release bundle, whose `share/sol/<version>/migration-runner-image`
   pins its own runner by digest, and an installed Sol refuses
   `SOL_MIGRATION_RUNNER_IMAGE` because a release uses only its own assets
   (DEC-049). `live-row.sh` requires `SOL_INSTALL`, records the bundle version
   and that digest in `sol-identity.txt`, and hands Sol no runner reference.

6. `sol deploy <target> --image-ref <svc>=<repo>@sha256:<digest>` per
   service, using step 5's app-image digests — exercises `B1`/`B2` and
   `C1`-`C5` (migration gate before workload mutation; the new namespace +
   RoleBinding bootstrap actually running as the deploy identity for the first
   time ever, not a hand-configured broad credential). The migration
   prerequisite uses the release bundle's own digest-pinned runner.
7. `B3`-`B7`: one representative transaction; a deliberately failed deploy;
   rollback to the prior release (and across a `contract` migration
   boundary, expecting a refusal); drift detection/correction. B3's `-svc`
   half runs through the qualification transport (§ *Qualification transport
   into private application services*), and its `-worker` half must show the
   application effect, not broker progress (DEC-039 §5). A degraded
   fixture is not repaired here: § *Re-establishing a workload fixture* is the
   reset, and it is a teardown and recreate, not a redeploy.
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
   (`internal/ci/check_production_infra.py`,
   `internal/ci/context/test_cloud_lifecycle_offline.sh`,
   `internal/ci/test_publisher_deployer_boundary.sh`) are entirely this
   tier. Necessary, never sufficient.
2. **Mechanism/renderability evidence** — `sol cloud plan` producing correct
   Deferred/Plannable phases; `terraform validate`/`fmt` clean; an RBAC
   binding structurally namespace-scoped rather than cluster-wide; the
   lifecycle's transition/policy semantics as asserted by the unit tests and
   `internal/ci/context/test_cloud_lifecycle_offline.sh`. All of this is already proven
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
