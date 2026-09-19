# Provider-neutral Sol invariants

**Derived:** 2026-09-19 · **Last verified:** `main @ 7ea2ef43`
**Scope:** the `sol cloud` target lifecycle for the `production-single-region`
profile. Provider neutrality means *the same semantic property may be realized
through different provider mechanisms* — it does **not** mean AWS and GCP must
share a mechanism.

Each invariant is grounded in an existing Sol decision, implementation or run
record, or is explicitly marked **[PROPOSED — needs confirmation]**. Status
columns use the shared evidence taxonomy (`STATIC` / `MECHANISM` /
`BEHAVIORAL`) defined in `../README.md`. "Unqualified" never means "false"; it
means "not yet established by evidence that could have failed".

IDs are stable: `INV-<group>-<n>`. The summary table below uses the short form
(`AUTH-1`); each section heading uses the full ID (`INV-AUTH-1`). Findings live in
`../findings/FND-*.md`; the compact roll-up is `../QUALIFICATION_STATUS.md`.

---

## Summary

| ID | Property (short) | AWS | GCP |
|---|---|---|---|
| AUTH-1 | Target authority is explicit, never ambient | QUALIFIED (behavioral, partial) | MECHANISM |
| AUTH-2 | Authentication ≠ authorization (reach ≠ in-cluster rights) | HOLDS (static) | **DEFECT** (FND-0001/INFRA-043) |
| AUTH-3 | Install authority exists only during the transitions requiring it | QUALIFIED (behavioral) | MECHANISM |
| AUTH-4 | Revoking bootstrap revokes the *effective* capability (no surviving path) | **DESIGN GAP** (FND-0002) | **DEFECT** (FND-0001) |
| AUTH-5 | Steady-state identities hold only intended capabilities | QUALIFIED (partial) | GAP (publisher/deployer contract unimplemented) |
| DESTROY-1 | Every infra-holding state has a Sol path to `Absent` | QUALIFIED (behavioral) | **DEFECT** (FND-0004/INFRA-042) |
| DESTROY-2 | Normal activity never makes a target undeletable via the lifecycle | QUALIFIED (behavioral) | MECHANISM |
| DESTROY-3 | Provider resource graph stays provider-owned; Sol sequences roots | QUALIFIED (behavioral, AWS-only lifecycle) | MECHANISM |
| DESTROY-4 | Terraform success ≠ provider-side absence | QUALIFIED (behavioral) | QUALIFIED (behavioral, once) |
| DESTROY-5 | Emergency cleanup ≠ proof the normal destroy passed | OBSERVATION | OBSERVATION |
| RET-1 | Retention is explicit; `none` = no surviving billable artifacts | MECHANISM (**behavioral gap**) | BLOCKED (not expressible) |
| RET-2 | Protection, retention and preparation are separate | QUALIFIED (AWS route) | MECHANISM |
| CRED-1 | Credentials resolved per mutation, fail closed before billable work | QUALIFIED (behavioral) | MECHANISM |
| CRED-2 | Ambient kubeconfig/cloud state never selects target authority | QUALIFIED (behavioral) | MECHANISM |
| PREREQ-1 | Host toolchain prerequisites fail before billable work | OBSERVATION | MECHANISM |
| IDENT-1 | Rendered producer/consumer agree on identity and namespace | **DEFECT** (FND-0008/INFRA-040) | not exercised |
| EVID-1 | Static / mechanism / behavioural evidence kept distinct | convention (partial) | convention (partial) |
| EVID-2 | Assertions are demonstrably falsifiable | MECHANISM (partial) | MECHANISM (partial) |
| EVID-3 | Provider docs establish contracts, not Sol qualification | policy | policy |
| EVID-4 | A claim is scoped to (target, revision, profile, evidence) | policy (matrix) | not yet applicable |
| SUBSTRATE-1 | Platform substrate capabilities realized per provider, semantics shared | QUALIFIED (behavioral) | MECHANISM |
| SUBSTRATE-2 | Provider differences recorded, not hidden by a shared abstraction | convention | convention |

Legend: QUALIFIED / MECHANISM / STATIC / GAP / DEFECT / BLOCKED / OBSERVATION.

---

## Authority

### INV-AUTH-1 — Target authority is explicit, not ambient

**Statement.** The identity that reconciles a target is declared by the target
and selected by Sol, never inferred from whatever AWS/GCP/kube credentials
happen to be in the caller's environment.

**Rationale.** DEC-026 §4 requires named provisioning/deploy/operator identities
distinct from any cluster-creator admin; ADR 0002 forbids cluster-creator admin
and ambient kubeconfig; DEC-020 removed the ambient-kubectl fallback. The
qualification inventory restates it as "never use ambient kubeconfig".

**Realization.**

| | AWS | GCP |
|---|---|---|
| Mechanism | target `provisioner_role_arn`/`deploy_role_arn`/`operator_role_arn`; cloud apply runs as the operator's resolved AWS identity; cluster access via `aws eks update-kubeconfig --role-arn <provisioner_role_arn>` into an ephemeral kubeconfig | target-declared `provisioner_impersonator`; cluster access via `gcloud container clusters get-credentials --impersonate-service-account <provisioner SA>` |
| Difference | role assumption per call | short-lived impersonation of a service account |

**Provider-contract sources.** AWS CLI `update-kubeconfig`
(https://docs.aws.amazon.com/cli/latest/reference/eks/update-kubeconfig.html);
GCP service-account impersonation
(https://cloud.google.com/iam/docs/service-account-overview).

**Qualification.**

| Tier | AWS | GCP |
|---|---|---|
| STATIC | `sol_cli_credentials.resolve` + `require_credentials` (`cmd_cloud_tf.ml:807`); `provisioner_kubeconfig` passes `--role-arn` and an explicit `--kubeconfig` | `gcp_provisioner_kubeconfig` passes `--impersonate-service-account` (`cmd_cloud_tf.ml:740-780`) |
| MECHANISM | ephemeral kubeconfig created and deleted per invocation | same, via `$KUBECONFIG` |
| BEHAVIORAL | Run 2/5/6 ran as a scoped identity; Run 5 Attempt 5 and Run 6 fell back to a static `Administrator` profile on SSO expiry — a **recorded deviation**, not a qualification | Attempt 3 obtained credentials as `sol-qual-provisioner@…` and reached the cluster |

**HARDEN evidence.** HARDEN-002 Run 5 Attempt 5 (deviations §1) and Run 6
Attempt 6 (§deviations 1); GCP inventory Attempt 3.

**Open findings/tickets.** None specific; the AWS `Administrator` fallback is a
deviation that must not become the product answer (INFRA-039 covers the
fail-closed half).

**To move AWS to fully qualified.** A run in which the declared scoped
provisioner credential is the only one used for *teardown* (Run 5/6 both used
the static fallback for destroy).

---

### INV-AUTH-2 — Authentication and authorization are separate; reach ≠ in-cluster rights

**Statement.** A cloud identity's ability to *authenticate to* a cluster API
does not by itself grant Kubernetes authorization; in-cluster rights come from
an explicit authorization mechanism (RBAC or the provider's access-policy
mapping).

**Rationale.** ADR 0002/0003 split "the authority to reach the cluster" from
"the authority to act in it"; the GCP inventory asserts "IAM establishes cluster
discovery/credential access; Kubernetes RBAC establishes Sol authority".

**Realization & status.**

| | AWS | GCP |
|---|---|---|
| Mechanism | EKS access entry maps the IAM principal to Kubernetes groups; authorization is RBAC. IAM alone grants no in-cluster rights. | GKE authorizes via RBAC **first**, then **IAM as a fallback**: an IAM role carrying `container.*` permissions authorizes Kubernetes API operations. |
| Verdict | **HOLDS** (static; IAM is not an in-cluster authorizer) | **VIOLATED** — see FND-0001 / INFRA-043 |

**Provider-contract sources.**
- AWS access entries / policy permissions:
  https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html,
  https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html
- GKE RBAC doc (IAM fallback): https://cloud.google.com/kubernetes-engine/docs/how-to/role-based-access-control
  ("To authorize an action, GKE checks for an RBAC policy first. If there isn't
  an RBAC policy, GKE checks for IAM permissions.")
- Kubernetes Engine Developer role:
  https://cloud.google.com/iam/docs/roles-permissions/container
  ("Provides access to Kubernetes API objects inside clusters.")

**Open findings/tickets.** FND-0001 = INFRA-043. The GCP code comment
(`cli/platform/infra/gcp/main.tf:254-255`) and the inventory
(`gcp-bootstrap-inventory.md:302`) both state the refuted version.

**To move GCP to qualified.** Narrow the provisioner IAM role to
cluster-discovery/credential retrieval only, then demonstrate a denied workload
operation with no RBAC policy supplying it (INFRA-043 acceptance criteria).

---

### INV-AUTH-3 — Install authority exists only during the transitions that require it

**Statement.** Privileged installation authority is granted for the install /
privileged-update phases and revoked at the verified transition out of them; it
is not a standing grant.

**Rationale.** ADR 0003 invariants 1 and 3. ADR 0002's forward sequence steps
4–10; the phase table.

**Realization.**

| | AWS | GCP |
|---|---|---|
| Open | cloud apply runs with `provisioner_bootstrap_admin=true`, associating `AmazonEKSClusterAdminPolicy` with the provisioner access entry | cloud apply runs with `provisioner_bootstrap_admin=true`, creating a cluster-admin `ClusterRoleBinding` for the provisioner service account |
| Close | re-apply with `provisioner_bootstrap_admin=false` removes the association | re-apply with the var false removes the binding |
| When | after the full platform apply **and** verified readiness | same |

**Qualification.**

| Tier | AWS | GCP |
|---|---|---|
| STATIC | `access_entries` policy_associations keyed on `var.provisioner_bootstrap_admin` (`aws/main.tf:153-181`) | `kubernetes_cluster_role_binding.provisioner_bootstrap_admin` `count = var.provisioner_bootstrap_admin` (`gcp/main.tf:284-300`) |
| MECHANISM | association created then removed by the two applies | binding created then removed |
| BEHAVIORAL | Run 5 Attempt 5 rows I1–I3/I5–I6; the window stayed open through the whole platform apply (finding 14's fix) | Attempt 3 revoked the window on the **failure** path (`provisioner-bootstrap-access-remove` ok in 8.7 s) |

**HARDEN evidence.** HARDEN-002 Run 5 Attempt 5 (conformant, rows I1–I6); GCP
inventory Attempt 3. Runs 3/4 found findings 13–15 but their bundles are not in
the tree and may not be cited as qualification (HARDEN-002 §"What is not
recorded").

**To move GCP to fully qualified.** A *successful* GCP `PlatformInstalling ->
Ready` transition (Attempt 3 failed during install, so the success-path
revocation is not yet observed).

---

### INV-AUTH-4 — Revoking bootstrap authority must revoke the *effective* capability

**Statement.** Removing one grant is not enough if another authorization path
can still produce the privileged capability. After the bootstrap window closes,
no path available to the steady-state identity may yield the bootstrap-only
capability.

**Rationale.** This is a semantic extension of ADR 0003 invariant 2 ("cannot
manufacture a more powerful identity"), the matrix I3 boundary, and
`production-bootstrap.md:128`. It exists because INFRA-043 showed the stated
boundary was true of one mechanism and false of another.

**Realization & status.**

| | AWS | GCP |
|---|---|---|
| Surviving path? | **Yes, latent**: the provisioner IAM policy grants `eks:*` (`bootstrap/main.tf:81`), which includes `eks:AssociateAccessPolicy`; the provisioner can associate `AmazonEKSClusterAdminPolicy` with its own access entry and obtain full cluster admin at will. | **Yes, continuous**: the provisioner service account's project-level `roles/container.developer` authorizes Kubernetes API writes through GKE's IAM fallback, with no Sol action. |
| Verdict | **`DESIGN_GAP`** — the AWS behaviour is documented and correct; the stated invariant ("cannot manufacture a more powerful identity") and the single-identity design are misaligned, and closing the gap requires a design decision (split cloud-provisioning from steady-state cluster-access identity, or restate the invariant) | **`VERIFIED_DEFECT`** — FND-0001 / INFRA-043 |

**Provider-contract sources.**
- `eks:AssociateAccessPolicy` is the permission required to associate access
  policies: https://docs.aws.amazon.com/eks/latest/userguide/access-policies.html
- `AmazonEKSClusterAdminPolicy` "includes permissions that grant an IAM principal
  administrator access to a cluster" (`* * * * *`):
  https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html
- GKE IAM fallback and `container.developer`: as INV-AUTH-2.

**HARDEN evidence.** Neither path has been exercised adversarially. The AWS
post-closure check (`provisioner_authorization_established`) probes Kubernetes
`can-i` only — it cannot observe an AWS-API path. The GCP inventory's
`PlatformInstalling -> Ready` row names positive/negative `can-i` but no live
run has executed the full boundary.

**Open findings/tickets.** FND-0001 (defect → INFRA-043), FND-0002
(`DESIGN_GAP`, no ticket — needs a decision), FND-0003 (effective-capability
qualification gap).

**To move to qualified.**
- GCP: narrow the role and demonstrate a denied operation (INFRA-043).
- AWS: decide whether the provisioner IAM role may retain access-entry
  management; if yes, restate the invariant in terms of the K8s RBAC layer and
  record the cloud-API capability as accepted residual. If no, split the cloud
  provisioning identity from the steady-state cluster-access identity and
  re-run the post-closure probe.

---

### INV-AUTH-5 — Steady-state identities hold only their intended capabilities

**Statement.** Each named identity (provisioner, publisher, deployer, operator)
holds the capabilities its role requires and no others; negative boundaries are
explicit denies, not omissions.

**Rationale.** ADR 0002 identity table; `production-bootstrap.md` §2; the deploy
policy's explicit `NoInfrastructureOrIdentityMutation` deny.

**Realization.**

| | AWS | GCP |
|---|---|---|
| Provisioner | policy contract (`bootstrap/main.tf:75-129`): infra `*`, ECR lifecycle; explicit ECR-publish **deny**; K8s RBAC bounded to platform namespaces | `roles/container.developer` (see INV-AUTH-2/4) + RBAC; no explicit deny |
| Publisher | `publisher_policy_json` ECR push only; explicit deny infra/IAM/repo-lifecycle | **no contract implemented** in `gcp/main.tf` |
| Deployer | `deploy_policy_json` DescribeCluster only + explicit `NoInfrastructureOrIdentityMutation` deny; EKS access entry group `sol:deployers` + namespace-scoped RBAC | **no contract implemented**; GKE has no access-entry equivalent |
| Operator | `operator_policy_json` read-only | **not implemented** |

**Qualification.**

| Tier | AWS | GCP |
|---|---|---|
| STATIC | policies generated at `bootstrap/main.tf`; `check_production_infra.sh` asserts no `escalate`/`bind` | only the provisioner identity exists |
| MECHANISM | deploy boundary (INFRA-025) wired | provisioner impersonation works (Attempt 3) |
| BEHAVIORAL | Run 1 F5: deploy identity allowed `DescribeCluster`, denied `ec2:*`/`iam:*`/`eks:CreateCluster`; Run 5 Attempt 5 recorded the corrected negative `can-i` (`bind`/`escalate` denied) | none |

**GCP note.** The inventory *proposes* publisher/deployer/operator service
accounts; the current root implements only the provisioner (plus Loki/Thanos
workload identities). This is a GCP capability gap, owned by the GCP agent, not
an AWS-parity defect to fix here.

**Open findings/tickets.** FND-0003 (comprehensive four-identity
effective-permission qualification is the open row ADR 0002 assigns to
"Finding 6"); FND-0002 for the provisioner's cloud-API path.

---

## Lifecycle and destruction

### INV-DESTROY-1 — Every infrastructure-holding state has a Sol-controlled path to `Absent`

**Statement.** Destruction is an abort edge available from every phase that can
hold infrastructure, not a forward transition gated on a healthy target.

**Rationale.** ADR 0003 invariant 6; `destruction_available`. A failed install
is the state a target is most likely to be in.

**Realization.** AWS and GCP share the phase model in
`Sol_cli_cloud_lifecycle`; the provider difference is which root owns the
install-window object (AWS: cloud-root access entry; GCP: cloud-root RBAC
binding), not the destruction semantics.

**Qualification.**

| Tier | AWS | GCP |
|---|---|---|
| STATIC | `destruction_available` admits every non-`Absent` phase; offline harness asserts a partially-installed target is destructible | same model |
| MECHANISM | `enter_destruction` + destroy lifecycle | same |
| BEHAVIORAL | Run 5 Attempt 1 destroyed a target whose platform install failed (finding 16); Run 6 completed a normal destroy | **counterexample**: Attempt 3's platform install failed and `platform-destroy` then failed with "API did not recognize GroupVersionKind (CRD may not be installed)"; cloud removed by the emergency path |

**HARDEN evidence.** HARDEN-002 Run 5 Attempt 1 (abort path), Run 6; GCP
inventory Attempt 3.

**Open findings/tickets.** FND-0004 = **INFRA-042** (GCP partial install not
destructible through the lifecycle).

**To move GCP to qualified.** A GCP run in which a deliberately interrupted
platform install is destroyed through `sol cloud destroy` alone, with provider
APIs confirming absence and no emergency-path deletion.

---

### INV-DESTROY-2 — Normal lifecycle activity must not make a target undeletable

**Statement.** Any resource a target root creates that ordinary activity can
populate must be removable by that root's destroy, with its contents.

**Rationale.** ADR 0004 (HARDEN-002 Run 5 Attempt 5: ECR repositories filled by
publishing blocked destroy). Stated as a lifecycle property, not a list of
Terraform arguments.

**Realization.**

| | AWS | GCP |
|---|---|---|
| Mechanism | `force_delete = true` on ECR; no `prevent_destroy`; object storage force-destroyed | `force_destroy = true` on GCS buckets; no `prevent_destroy` |
| Guard | `internal/ci/check_destroy_completeness.sh` + mutation test | same guard covers GCP roots |

**Qualification.**

| Tier | AWS | GCP |
|---|---|---|
| STATIC | `aws/main.tf:210` (`force_delete`), `check_destroy_completeness.sh` | `gcp/main.tf` `force_destroy = true`; same guard |
| MECHANISM | offline harness | offline harness |
| BEHAVIORAL | Run 5 Attempt 5 (ECR failure → fix), Run 6 destroy completed | Attempt 3 destroy reached network + peering absent (once) |

**HARDEN evidence.** ADR 0004; HARDEN-002 Run 5 Attempt 5 finding 21; Run 6
teardown.

**Open findings/tickets.** None. The ADR 0004 invariant is qualified on AWS and
partially on GCP.

---

### INV-DESTROY-3 — Provider resource graphs remain provider-owned

**Statement.** Where Terraform/provider semantics can express the dependency
graph, Sol does not reimplement it; Sol sequences the two roots and applies
phase policy, and lets Terraform order resources.

**Rationale.** ADR 0002 (roots stay independent; Sol owns the semantic
dependency); GCP inventory: "Terraform remains authoritative for its own
resources and dependency graph. Sol only sequences the two roots, validates
their typed outputs, applies phase policy, and verifies live postconditions."

**Realization.** AWS: one cloud root + one platform root, staged cert-manager
apply inside the platform sequence (finding 5). GCP: cloud root + `base-gcp`
root calling the shared `base` definition.

**Qualification.** STATIC/MECHANISM both providers. BEHAVIORAL only on AWS
(Run 5/6). The GCP service-networking `time_sleep` episode is the boundary case
where a provider-side wait was modelled in Terraform and then withdrawn (see
FND-0005).

**Open findings/tickets.** FND-0005.

---

### INV-DESTROY-4 — Terraform success/state removal does not establish provider-side absence

**Statement.** After destroy, absence is verified independently through provider
APIs; a zero exit status is not absence evidence.

**Rationale.** ADR 0002 step "verify absence"; `production-bootstrap.md`
destroy procedure step 5; GCP `verify_gcp_destroy` comment ("abandonment is only
defensible against a check that can see the thing that was abandoned").

**Realization.** AWS `verify_aws_destroy` (EKS/RDS/ECR/load balancers) plus the
harness VPC check; GCP `verify_gcp_destroy` (GKE/Cloud SQL/VPC/Artifact
Registry/peering address/network/peering list).

**Qualification.**

| Tier | AWS | GCP |
|---|---|---|
| STATIC | `cmd_cloud_tf.ml:343-395` | `cmd_cloud_tf.ml:409-506` |
| MECHANISM | describe calls fail closed | gcloud describe/list calls fail closed |
| BEHAVIORAL | every HARDEN teardown; Run 5 Attempt 5 explicitly recorded that "command completion is not infrastructure truth" (describe still showed resources momentarily) | Attempt 3 verified absence by provider API, not Terraform exit status |

**Important scope limit (AWS).** `production-bootstrap.md:293-301` records that
**elastic IPs, NAT gateways and EBS volumes are not automatically checked** and
remain a manual sweep. This is a real qualification gap in the AWS absence
claim, not an absence of the invariant.

**Open findings/tickets.** FND-0003 (AWS absence coverage gap: EIP/NAT/EBS).

---

### INV-DESTROY-5 — Emergency cleanup is evidence of a non-conformant normal lifecycle

**Statement.** When the normal destroy cannot complete and an emergency path is
used, that is a finding against the normal lifecycle, never proof that destroy
passed.

**Rationale.** HARDEN-002 Run 5 Attempt 5 (ECR force-delete, manual snapshot
deletion, teardown under a different profile), Run 6 (manual snapshot
deletion), GCP Attempts 1–3 (cloud layer removed by the emergency path). The
runs deliberately recorded these as deviations.

**Qualification.** OBSERVATION both providers — the discipline exists and is
practised in the run records; it is not a code property to test.

---

## Retention

### INV-RET-1 — Retention is explicit, and `none` means nothing billable survives

**Statement.** A target states what its destruction deliberately keeps. A
disposable target's postcondition is literal absence with no residual billable
artifact, achieved without a manual step.

**Rationale.** DEC-033; ADR 0004 "Retention is a separate, explicit decision".

**Realization.** `destroy_retention: final-snapshot | none` on the target;
the Destroy policy reads it; `sol cloud destroy` prints a retention report.

**Qualification.**

| Tier | AWS | GCP |
|---|---|---|
| STATIC | `policy_vars` + `retention_report`; target parsing carries the field (INFRA-041 fix) | GCP cannot express retention: Cloud SQL deletes backups with the instance, so a target using the `final-snapshot` default is **refused** rather than destroyed |
| MECHANISM | offline harness asserts **both** modes: `none` prepares without a snapshot identity and `final-snapshot` still fails closed on disagreement | refuse-before-destroy is the mechanism |
| BEHAVIORAL | **GAP.** No run has yet reached `Absent` under `destroy_retention: none` without a manual deletion. Run 6 declared `none` and still had to delete a snapshot by hand (INFRA-041); Run 5 Attempt 5 declared nothing and deleted the snapshot by hand | N/A (retention inexpressible) |

**HARDEN evidence.** INFRA-041 resolution (both-ways harness); HARDEN-002 Run 6
(deviation 4: stray snapshot deleted by hand).

**Open findings/tickets.** FND-0006 = **INFRA-041** (fixed; live postcondition
still unqualified).

**To move AWS to qualified.** A disposable target declaring
`destroy_retention: none` reaching `Absent` with the retention report naming
nothing retained and **no** manual snapshot deletion.

---

### INV-RET-2 — Deletion protection, retention and destroy preparation are separate

**Statement.** A safety guard on a live resource (deletion protection), what a
destroy deliberately keeps (retention), and the applied transition that makes
destruction legal (preparation) are three concepts, not one `force_destroy`.

**Rationale.** ADR 0004; INFRA-023; `gcp-bootstrap-inventory.md` reconciliation
table.

**Realization.**

| | AWS | GCP |
|---|---|---|
| Protection | `rds_deletion_protection` (default true) | `sql_deletion_protection` (Terraform flag) **and** `settings.deletion_protection_enabled` (API flag); `gke_deletion_protection` |
| Retention | final RDS snapshot, unique per-attempt id | not expressible |
| Preparation | targeted apply disabling protection + setting a unique snapshot id | targeted apply on both guarded resources |

**Qualification.** STATIC both. MECHANISM: AWS offline harness (INFRA-023) and
GCP prepare (Attempt 2, 21 s). BEHAVIORAL: AWS Run 5 Attempt 5 (finding 15's
destroy-policy ordering produced a real unique snapshot confirmed `available`);
GCP Attempt 2 lifted both guards and verified, but the run then failed at
cluster access, so the sequence is not fully qualified end-to-end.

**Open findings/tickets.** FND-0003 (GCP prepare-to-destruction sequence not
qualified end to end).

---

## Credentials and host prerequisites

### INV-CRED-1 — Credentials are resolved per mutation and fail closed before billable work

**Statement.** A long-running lifecycle re-resolves its credentials at each
mutating boundary and refuses before doing work it cannot authenticate, rather
than discovering expiry mid-operation.

**Rationale.** INFRA-039 (Run 5 Attempt 5: an SSO refresh token expired mid-run;
the CLI still answered while Terraform could not, and teardown of a billable
target could not authenticate).

**Realization.** AWS: `aws configure export-credentials` per stage, printing the
principal; GCP: `gcloud auth application-default print-access-token` per stage.
Both fail closed with a message naming the operation and, for destroy, that the
target may still be billing.

**Qualification.** STATIC + MECHANISM both. BEHAVIORAL: AWS Run 6 detected the
expired SSO profile **up front** and used a static credential by explicit
deviation; GCP not yet exercised in a long run.

---

### INV-CRED-2 — Ambient kubeconfig/cloud state must not select target authority

**Statement.** Sol uses the target's cluster credentials in an ephemeral,
per-invocation kubeconfig; it never lets an ambient `KUBECONFIG`, `current-context`
or default cloud profile silently choose the authority.

**Rationale.** ADR 0002 finding 12 (the Kubernetes provider reads
`KUBE_CONFIG_PATH`/`KUBE_CONFIG_PATHS`, not `KUBECONFIG`); DEC-020 removed the
ambient-kubectl fallback.

**Realization.** `Sol_cli_cloud_lifecycle.provisioner_kube_env` sets all three
variables (`KUBECONFIG`, `KUBE_CONFIG_PATH`, `KUBE_CONFIG_PATHS`) to the
ephemeral path; AWS passes an explicit `--kubeconfig`; the temp file is removed
on both success and `at_exit`.

**Qualification.** STATIC (`sol_cli_cloud_lifecycle.ml:270-272`;
`cmd_cloud_tf.ml:622-780`). MECHANISM: per-invocation temp file. BEHAVIORAL:
Run 5/6 platform applies ran through the ephemeral provisioner kubeconfig.

---

### INV-PREREQ-1 — Host toolchain prerequisites fail before billable work

**Statement.** A missing host tool is a host prerequisite in the same class as
Terraform itself, and is refused before provisioning billable infrastructure,
not discovered inside the apply.

**Rationale.** GCP Attempt 3 discovered `gke-gcloud-auth-plugin` *inside* the
platform apply, after GKE and Cloud SQL were provisioned and paid for.

**Realization.** `require_gcp_platform_toolchain` runs
`gke-gcloud-auth-plugin --version` and fails closed before the first platform
call (`cmd_cloud_tf.ml:712-728`). AWS has no dedicated preflight; the `aws` CLI
is exercised by credential resolution (`INV-CRED-1`) and cluster access, both
before the platform stage.

**Qualification.** GCP MECHANISM (added; not yet exercised live — no run has
used the fixed binary against a fresh target). AWS OBSERVATION.

**Open findings/tickets.** FND-0009.

---

## Application and resource identity

### INV-IDENT-1 — A rendered producer and consumer agree on object identity and namespace

**Statement.** When Sol renders both the producer and the consumer of an object
(a Secret, a ConfigMap, a namespace), they agree on its name and namespace, and
that identity is established once.

**Rationale.** INFRA-040 (HARDEN Run 6): the migration Job referenced
`secretRef{name: sol-secrets}` while the substrate created `sol-secrets-secrets`,
so no workload could be deployed to an AWS target. `runtime_secret_name` is
defined once but the creation template appended `-secrets` again.

**Realization.** Provider-neutral (manifest rendering), not a cloud mechanism.

**Qualification.** STATIC: the defect is confirmed in code
(`sol_cli_manifest_yaml.ml`). MECHANISM/BEHAVIORAL: **none** — the fix is not
implemented (INFRA-040 is open), so a live deploy cannot reach the workloads.

**Open findings/tickets.** FND-0008 = **INFRA-040** (open).

---

## Evidence discipline

### INV-EVID-1 — Static, mechanism and behavioural evidence are kept distinct

**Statement.** Configuration inspection, mechanism execution and demonstrated
behaviour are different tiers; a lower tier is never promoted to a higher one.

**Rationale.** HARDEN-002 acceptance criteria and matrix governing rule 3;
HARDEN-003.

**Qualification.** Convention adopted in `../README.md`, the matrix
(`behavioural` vs `inspection` tags) and the run records. INFRA-041 is the
clearest worked example: the offline harness is **mechanism** evidence and
explicitly says the live `Absent` postcondition remains unqualified.

### INV-EVID-2 — An assertion is demonstrated capable of failing

**Statement.** A qualification assertion must be shown to reject the violated
condition, not merely to pass.

**Rationale.** HARDEN-003 (a vacuous offline assertion; a stale port-forward).

**Qualification.** MECHANISM both providers: `internal/ci/qualification_assertions.sh`
+ `test_qualification_assertions.sh` (mutation test); `check_gcloud_interface.sh`
validates Sol's `gcloud` argv against the real CLI. Partial: the AWS
post-closure `can-i` checks are executed live but their ability to fail (and the
identity/authorizer they exercise) has not itself been demonstrated.

### INV-EVID-3 — Provider documentation establishes contracts, not Sol qualification

**Statement.** A documented provider guarantee is an input to qualification, not
a qualification result.

**Rationale.** DEC-026 governing invariant (a claim is about a `(target,
evidence)` pair); the matrix is explicitly "the input, not evidence".

**Qualification.** Policy, applied by this audit area. The research packet's
errors (see `../research/`) are the motivating case.

### INV-EVID-4 — A production claim is scoped to (target, code revision, profile, evidence)

**Statement.** Conformance is per target, per profile version, per code revision
and per timestamp; later code does not retroactively qualify an earlier run.

**Rationale.** DEC-026 §9 and matrix governing rule 1. HARDEN-002's own "runs 3
and 4 may not be cited as qualification" record is the application.

**Qualification.** Policy/template exists for AWS; GCP has no equivalent matrix
yet (`gcp-bootstrap-inventory.md` remaining gap 7).

---

## Provider substrate

### INV-SUBSTRATE-1 — Platform substrate capabilities are provider-realized, semantics shared

**Statement.** Sol's platform needs a default block-storage class backed by a
registered CSI driver and an ingress endpoint; the *mechanism* is the provider's,
the capability is Sol's.

**Rationale.** DEC-026 §2 (provider/Kubernetes mechanisms stay below the Sol
semantic boundary); HARDEN-002 finding 7 (EKS shipped no StorageClass);
`production-bootstrap.md` §Platform storage.

**Realization.**

| | AWS | GCP |
|---|---|---|
| Storage | EBS CSI addon + IRSA role + `gp3` default StorageClass, `WaitForFirstConsumer`, encrypted | adopts GKE's `standard-rwo` (`pd.csi.storage.gke.io`); creates no class |
| Ingress | `LoadBalancer` via in-tree cloud controller | same (ingress-nginx) |

**Qualification.** AWS BEHAVIORAL (Run 5 Attempt 5: PVCs bound, Redpanda 3×2/2,
readiness asserts the default class + EBS CSI). GCP MECHANISM/partial: Attempt 3
reached platform install but failed before readiness; the inventory records GCP
StorageClass presence, not a bound persistent workload.

**Open findings/tickets.** FND-0009.

### INV-SUBSTRATE-2 — Provider differences are recorded, not hidden

**Statement.** Where providers differ, the difference is named (root, backend,
identity mechanism, storage class, DNS solver) rather than papered over by a
lowest-common-denominator abstraction.

**Rationale.** `gcp-bootstrap-inventory.md` "AWS assumptions not to carry into
GCP"; ADR 0002 "GCP adopts the same semantic phase interface only after its own
live qualification"; the separate `base-gcp` root.

**Qualification.** Convention; exercised by the separate GCP root and the
inventory. This is why the invariants above do not require identical AWS/GCP
mechanisms.

