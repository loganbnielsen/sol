# Provider-contract verification — AWS/GCP HARDEN research packet (2026-09-19)

**Input:** `research/aws-gcp-harden-research_gemini-external.md` (a Gemini-produced
research index, externally supplied and originally untracked at repository root;
moved here on 2026-09-19 with a provenance header). Treated as an index of *claims*,
never as ground truth.

**Method.** For every claim: open the cited primary source and read it; if it does not
support the claim, find the source that does or discard the claim; then inspect the
Sol implementation and the existing HARDEN evidence; then classify. The
static/mechanism/behavioural separation used by `production-single-region-v1-matrix.md`
is preserved throughout — nothing here is promoted to behavioural evidence.

**Result.** One new, verified, actionable Sol defect (filed as **INFRA-045**). Ten of
the fifteen claims are confirmed and already satisfied by Sol — two of those (C2, D2)
had the wrong cited page but are true, with the correct source supplied. One claim
(E2) is corrected in substance. One claim (B2) is refuted by its own cited sources and
is the defect. One (G2) is an already-recorded known gap. Two (H1, I1) are genuinely
not documented and remain qualification gaps. Nothing is filed as a ticket except the
verified defect.

Source pages were retrieved directly and read (not inferred from snippets); the exact
URLs are listed in §Sources. Where the registry page is a JavaScript shell, the
provider doc was read from the generated Markdown in the provider's own repository,
which is the same text the registry renders.

---

## 1. Claim-by-claim verdicts

| # | Claim (abbreviated) | Primary source | Verdict | Sol surface | Disposition |
|---|---|---|---|---|---|
| A1 | `aws-auth` ConfigMap deprecated; use CAM / access entries | AWS CAM best practices | **Confirmed** | access entries via `terraform-aws-modules/eks` | Addressed; observation only |
| A2 | EKS creator gets admin; disable bootstrap creator admin | `aws_eks_cluster` | **Confirmed** | `enable_cluster_creator_admin = false` default | Addressed (HARDEN live) |
| B1 | GCP impersonation needs `serviceAccountTokenCreator` | GCP SA overview | **Confirmed** | `provisioner_impersonators` on one SA | Addressed |
| B2 | `roles/container.developer` cannot authorize workloads | GKE auth / RBAC docs | **Refuted** | project-level `container.developer` on provisioner | **DEFECT → INFRA-045** |
| C1 | `aws eks update-kubeconfig` merge/exec semantics | AWS CLI reference | **Confirmed** | ephemeral `--kubeconfig` + `KUBE_CONFIG_*` | Addressed |
| C2 | GKE 1.26+ requires `gke-gcloud-auth-plugin` | cluster-access doc (not the cited page) | **Confirmed**, citation corrected | `require_gcp_platform_toolchain` | Addressed (HARDEN live) |
| D1 | RDS destroy needs `skip_final_snapshot` or snapshot id | `aws_db_instance` / `rds_cluster` | **Confirmed** | separate `rds_skip_final_snapshot` / id | Addressed (finding 9) |
| D2 | VPC delete deadlocks on K8s-managed resources | AWS VPC delete + EKS network reqs (not the cited page) | **Confirmed**, citation corrected | LB wait + absence verification | Addressed, bounded |
| E1 | Cloud SQL `deletion_protection` blocks destroy | `google_sql_database_instance` | **Confirmed** | both provider + API flags, default true | Addressed (HARDEN live) |
| E2 | Service Networking `deletion_policy=ABANDON` bypasses locks | `google_service_networking_connection` (not the cited resource) | **Corrected**: ABANDON *leaves* the peering, which blocks network deletion | ABANDON on the correct resource + independent verification | Behaviourally qualified once; upper bound open |
| F1 | EKS/IAM destroy ordering needs `depends_on` | `aws_eks_cluster` | **Confirmed** | module's cluster resource carries `depends_on` | Addressed |
| G1 | cert-manager Route53 DNS-01 via IRSA trust | cert-manager Route53 | **Confirmed** | `cert_manager_irsa`, `cert-manager:cert-manager` | Addressed |
| G2 | cert-manager has a CloudDNS solver | cert-manager API docs | **Confirmed** | not used; issuers hard-wire Route53 | Known gap (GCP inventory #1) |
| H1 | K8s finalizer/partial-install destroy deadlocks | *not documented* (Gemini agrees) | **Not documented** | INFRA-042 covers the CRD-absent variant | Qualification gap |
| I1 | EKS/GKE default StorageClasses differ | *not documented* (Gemini agrees) | **Not documented** | provider-specific StorageClass handling | Qualification gap |

---

## 2. Detail

### A1 — `aws-auth` deprecated in favour of CAM API — CONFIRMED

Primary source says, verbatim:

> ConfigMap-based access management (aws-auth ConfigMap) is deprecated and replaced
> by Cluster Access Management (CAM) API. For new EKS clusters, implement CAM API to
> manage cluster access.

and describes access entries as the object that links IAM principals to a cluster,
with access policies carrying "Kubernetes permissions only".

**Sol:** the AWS root drives `terraform-aws-modules/eks/aws ~> 20.8`
(`cli/platform/infra/aws/main.tf:76-78`) and supplies `access_entries` for the
provisioner and deploy identities (`main.tf:153-181`), which is CAM. The module
hardcodes `bootstrap_cluster_creator_admin_permissions = false` and models the
creator-admin case as a controllable access entry (module `main.tf:35-43,
142-160`).

**Observation, not a defect:** Sol never sets `authentication_mode`, so the module
default `API_AND_CONFIG_MAP` is used (verified in v20.24.0, v20.8.0 and v20.31.6
READMEs). That mode *permits* the deprecated ConfigMap path, but module v20 no longer
creates or manages an `aws-auth` ConfigMap at all — it manages access exclusively
through access entries. Sol therefore does not use the deprecated mechanism; no
ticket. (Recorded so a future reader does not re-derive this and file it as a gap.)

### A2 — EKS bootstrap creator admin — CONFIRMED

The `aws_eks_cluster` provider doc documents
`access_config.bootstrap_cluster_creator_admin_permissions`: "Whether or not to
bootstrap the access config values to the cluster. Default is `true`."

**Sol:** `enable_cluster_creator_admin` defaults `false`
(`cli/platform/infra/aws/variables.tf:182-187`) and is passed to the module
(`main.tf:151`). HARDEN-002 Run 2 and Run 5 record live evidence: the EKS API denied
the cluster-creator admin and all work ran through a scoped access entry
(`HARDEN-002.md:295-297, 420`). Addressed and behaviourally qualified on AWS.

### B1 — GCP impersonation role — CONFIRMED

Source: "to let a user impersonate a service account, you could grant the user the
Service Account Token Creator role (`roles/iam.serviceAccountTokenCreator`) on the
service account."

**Sol:** `google_service_account_iam_member.provisioner_impersonators` grants exactly
that role on the one provisioner service account to target-declared members
(`cli/platform/infra/gcp/main.tf:349-356`); impersonation is used for short-lived
tokens, no JSON keys. Addressed. (Note the doc says "could", not "must": the underlying
requirement is `iam.serviceAccounts.getAccessToken`, which this role supplies.)

### B2 — `roles/container.developer` and Kubernetes authority — REFUTED → DEFECT

Gemini claimed `roles/container.developer` "provides authentication to the GKE cluster
API but does not natively authorize workload deployment". The cited page does not say
that; it says the opposite:

- `gke-auth`: "The following example grants the `roles/container.developer` IAM role,
  which **provides access to Kubernetes API objects inside clusters**."
- GKE RBAC doc: "To authorize an action, GKE checks for an RBAC policy first. If
  there isn't an RBAC policy, **GKE checks for IAM permissions**. In GKE, IAM and
  Kubernetes RBAC are integrated to authorize users to perform actions if they have
  sufficient permissions according to either tool."
- The IAM role reference for Kubernetes Engine Developer states "Provides access to
  Kubernetes API objects inside clusters. Lowest-level resources where you can grant
  this role: Project", and lists the granted permissions — including
  `container.deployments.*`, `container.pods.*` (including `pods.exec`),
  `container.namespaces.*`, `container.jobs.*`, `container.replicaSets.*`,
  `container.daemonSets.*`, `container.configMaps.*` and `container.secrets.*`.

Sol's GCP root makes the same false claim in a load-bearing code comment:

```
#   * `roles/container.developer` is what lets it *reach* the cluster (fetch
#     credentials and read the cluster), and it confers no Kubernetes authority
#     by itself;
```

(`cli/platform/infra/gcp/main.tf:254-255`), and then grants that role at **project**
level to the provisioner service account (`main.tf:321-324`). The same identity is the
steady-state platform provisioner bound by the RBAC in
`cli/platform/infra/base/platform_provisioner_rbac.tf`. The GCP qualification inventory
repeats the claim ("IAM establishes cluster discovery/credential access; Kubernetes
RBAC establishes Sol authority", `gcp-bootstrap-inventory.md:302`).

**Impact.** The provisioner service account holds continuous, project-wide Kubernetes
write authority via IAM — create/delete Deployments, Pods (including `exec`),
Namespaces, Secrets, ConfigMaps, Jobs, etc., on *any* cluster in the project —
regardless of the RBAC install window or the namespaced steady-state bindings. The
claimed boundary ("steady-state provisioner is bounded and non-escalatable",
ADR 0003 / inventory lifecycle row) is therefore not established by the RBAC alone.
The claim to falsify live is an **actual operation** (create a Namespace or a
Deployment as the provisioner with no RBAC policy granting it) — a
`kubectl auth can-i` probe is the natural instrument but should not be assumed to
reflect GKE's IAM authorizer in `SubjectAccessReview`; the qualifier must confirm the
instrument actually observes the IAM path before trusting a negative. This is exactly
what HARDEN-003 requires qualification evidence to be able to falsify.

**Filed as INFRA-045** (static/mechanism evidence + verified provider contract; the
live both-ways IAM-path demonstration remains the behavioural qualifier). The adjacent stale comment in
`cli/sol/bin/cmd_cloud_tf.ml:695-701` (still describing the GCP caller as the target's
Owner identity, while the code at `:755-756` already impersonates the provisioner
service account) is a documentation correction noted for the same pass; it is not
itself a provider-contract finding.

### C1 — `aws eks update-kubeconfig` — CONFIRMED

Source: with `--kubeconfig` the file is created/merged there; otherwise "the resulting
configuration file is created at the first entry in [`$KUBECONFIG`]"; the example
configures an `exec` credential plugin running `aws eks get-token`.

**Sol:** `provisioner_kubeconfig` passes an explicit temp `--kubeconfig` and
`--role-arn`, and exports `KUBECONFIG`, `KUBE_CONFIG_PATH` and `KUBE_CONFIG_PATHS` for
the child (`cli/sol/bin/cmd_cloud_tf.ml:622-659`;
`cli/sol/lib/sol_cli_cloud_lifecycle.ml:270-272`). Passing `--kubeconfig` means an
ambient `$KUBECONFIG` cannot redirect the write — which is the qualification
implication Gemini raised. Addressed.

### C2 — `gke-gcloud-auth-plugin` — CONFIRMED, citation corrected

The cited `api-server-authentication` page shows the plugin in an example kubeconfig
but never mentions 1.26. The authoritative statement is in *Install kubectl and
configure cluster access*: "Before Kubernetes version 1.26 is released, gcloud CLI
will start to require that the `gke-gcloud-auth-plugin` binary is installed. If the
plugin is not installed, existing installations of kubectl or other custom Kubernetes
clients stop working."

**Sol:** `require_gcp_platform_toolchain` runs `gke-gcloud-auth-plugin --version` and
fails closed before the first platform call, naming the install command
(`cli/sol/bin/cmd_cloud_tf.ml:712-728`). This was added after HARDEN's GCP Attempt 3
discovered the failure inside the platform apply
(`gcp-bootstrap-inventory.md:622-687`). Addressed and behaviourally motivated.

### D1 — RDS final snapshot — CONFIRMED

Sources: `aws_db_instance.final_snapshot_identifier` "Must be provided if
`skip_final_snapshot` is set to `false`"; `skip_final_snapshot` defaults `false`
(same for `aws_rds_cluster`).

**Sol:** the two are separate variables (`cli/platform/infra/aws/variables.tf:96-116`)
and the resource derives `final_snapshot_identifier` from the cluster name when a
snapshot is required (`main.tf:301-310`). HARDEN-002 finding 9 records the live
failure and the fix. Addressed and behaviourally qualified on AWS.

### D2 — VPC deletion and K8s-managed resources — CONFIRMED, citation corrected

The cited `aws_eks_cluster` page mentions the cross-account ENIs EKS creates, but the
claims are documented better elsewhere: AWS VPC delete — "Before you can delete a VPC,
you must first terminate or delete any resources that created a requester-managed
network interface in the VPC. For example, you must terminate your EC2 instances and
delete your load balancers, NAT gateways…"; EKS network requirements — "When you
create a cluster, Amazon EKS creates 2–4 elastic network interfaces in the subnets
that you specify."

**Sol:** the AWS destroy path removes the platform (which removes the ingress Service),
waits for load balancers to deprovision, then verifies their absence by the in-tree
`kubernetes.io/cluster/<name>` tag (`cli/sol/bin/cmd_cloud_tf.ml:281-338, 2017`), and
EKS ENIs are removed with the cluster. Addressed. Bounded and documented: the check
does not cover a standalone AWS Load Balancer Controller's `elbv2.k8s.aws/cluster`
tag, which is correct today because only ingress-nginx is installed.

### E1 — Cloud SQL deletion protection — CONFIRMED

Source: `deletion_protection` — "When the field is set to true or unset in Terraform
state, a `terraform apply` or `terraform destroy` that would delete the instance will
fail"; a separate note says newer providers require explicitly setting it `false` to
destroy. The API-level `settings.deletion_protection_enabled` is the protection that
holds across all surfaces.

**Sol:** `sql_deletion_protection` defaults `true`
(`cli/platform/infra/gcp/variables.tf:73-77`) and is applied to **both** the
provider-side flag and `settings.deletion_protection_enabled`
(`cli/platform/infra/gcp/main.tf:180-186`), with an applied, verified destroy
preparation. The inventory records the distinction and the live preparation
(`gcp-bootstrap-inventory.md:497-510`). Addressed.

### E2 — Service Networking `deletion_policy` — CORRECTED

Two corrections:

1. **Wrong resource.** Gemini cites
   `service_networking_vpc_service_controls`. That resource exists and does have a
   `deletion_policy`, but it manages VPC Service Controls route/DNS configuration, not
   the VPC peering. The resource that owns the peering is
   `google_service_networking_connection`.
2. **The consequence is inverted.** ABANDON does not "bypass VPC deletion locks". The
   connection doc says: "When set to `ABANDON`, the command will remove the resource
   from Terraform management without updating or deleting the resource in the API.
   **The VPC peering created by the connection is left in place, which will block
   deletion of the network.**"

**Sol:** it uses ABANDON on the correct resource
(`cli/platform/infra/gcp/main.tf:230-235`) after an earlier `time_sleep` attempt
failed, and compensates for the lost Terraform confirmation with an independent
`verify_gcp_destroy` that asks the provider for both the network and the peering
(`cli/sol/bin/cmd_cloud_tf.ml:409-500`). HARDEN's GCP Attempt 3 observed the peering
absent after the network was deleted and the lifecycle reach exit 0
(`gcp-bootstrap-inventory.md:658-686`). **No ticket:** the behavior is recorded and
qualified for one observation; GCP's producer-reference release has no documented
upper bound, which the inventory already states.

### F1 — EKS/IAM destroy ordering — CONFIRMED

`aws_eks_cluster` `role_arn` doc: "Ensure the resource configuration includes explicit
dependencies on the IAM Role permissions by adding `depends_on` … otherwise EKS cannot
delete EKS managed EC2 infrastructure such as Security Groups on EKS Cluster
deletion."

**Sol:** it uses `terraform-aws-modules/eks`, whose `aws_eks_cluster.this` resource
carries `depends_on = [aws_iam_role_policy_attachment.this, …]` (module `main.tf:98-104`).
The documented requirement is satisfied by the module; Sol does not manage the cluster
IAM role/policies out of band. Addressed.

### G1 — cert-manager Route53 IRSA — CONFIRMED

The cert-manager Route53 doc supplies the exact trust policy:
`sts:AssumeRoleWithWebIdentity`, `Federated` = the cluster's OIDC provider, `Condition`
`…:sub = system:serviceaccount:<namespace>:<service-account-name>`, plus the
`eks.amazonaws.com/role-arn` annotation.

**Sol:** `module "cert_manager_irsa"` binds the role to
`namespace_service_accounts = ["cert-manager:cert-manager"]` with
`provider_arn = module.eks.oidc_provider_arn`
(`cli/platform/infra/aws/main.tf:472-492`). The `iam-role-for-service-accounts-eks`
module generates the trust policy with `sts:AssumeRoleWithWebIdentity` and the `:sub`
condition (module `main.tf:39-56`). Addressed.

### G2 — cert-manager CloudDNS solver — CONFIRMED contract, KNOWN Sol gap

The API docs confirm the `cloudDNS` field of type
`ACMEIssuerDNS01ProviderCloudDNS`, "Use the Google Cloud DNS API to manage DNS01
challenge records."

**Sol:** does **not** use it. Both `ClusterIssuer`s in
`cli/platform/infra/base/cert_manager_issuer.tf:27-31, 53-58` are hard-wired to the
`route53` solver, and `base-gcp` reuses that shared definition. This is already
recorded as the first remaining gap in `gcp-bootstrap-inventory.md` (lines 29, 199,
305, 344, 693-698), and a GCP target declaring `cluster_issuer` is refused by name.
**No ticket** — it is a known, recorded gap, not a new finding.

### H1 — Finalizer / partial-install destroy deadlock — NOT DOCUMENTED

Gemini correctly labels this empirical. Sol's closest exposure is the platform root's
state referencing CRD-backed resources whose CRDs were never installed, which the GCP
qualification actually hit; it is filed as **INFRA-042** (a partially-installed GCP
platform is not destroyable through the lifecycle). No further ticket: the remaining
behaviour (how long Terraform's Kubernetes provider hangs, and recovery from orphaned
CRs/finalizers on a *complete* install) still requires live fault injection, which is a
HARDEN observation, not a code change.

### I1 — EKS/GKE StorageClass differences — NOT DOCUMENTED

Gemini correctly labels this empirical. Sol does not assume `StorageClass: default` is
portable: `kubernetes_storage_class_v1.platform_default` is created only when
`create_storage_class && cloud_provider == "aws"` (`cli/platform/infra/base/main.tf:1482-1489`,
with `WaitForFirstConsumer` for EBS's zonal nature), while GCP adopts GKE's
`standard-rwo` (`pd.csi.storage.gke.io`) and sets `create_storage_class = false`
(`base-gcp/variables.tf:37-44`). AWS is qualified by the matrix; GCP's StorageClass is
recorded as working in the inventory (`gcp-bootstrap-inventory.md:323`). Cross-provider
portability of stateful workloads remains a qualification gap, not a defect.

### Assumption-risk table

Derived from the claims above; it adds no new contract. The one row worth annotating:
"RDS and CloudSQL can be destroyed transparently" is correct that both are guarded by
default, but they are guarded by **different mechanisms** — AWS by
`skip_final_snapshot`/`final_snapshot_identifier` (a snapshot requirement), GCP by
`deletion_protection` + `settings.deletion_protection_enabled` (a refusal). Sol already
models them separately, which is why the two rows in §1 are not one finding.

---

## 3. Classification summary

**Verified Sol defect → ticket**

- **INFRA-045** — GCP provisioner's project-level `roles/container.developer` confers
  Kubernetes API authority, so the RBAC-only boundary the code and the qualification
  inventory claim is not real. (Static evidence + verified provider contract; the live
  both-ways IAM-path demonstration is the qualifier.)

**Confirmed contracts already satisfied by Sol (no action)**

A1, A2, B1, C1, C2, D1, D2, E1, F1, G1. Several are already behaviourally qualified by
HARDEN Runs 1–6 (A2, C2, D1, E1); the rest are confirmed by reading Sol's Terraform and
lifecycle code.

**Claim corrected / citation corrected (no action beyond the correction)**

- C2 — the 1.26 statement is in the cluster-access doc, not the cited auth page.
- D2 — the ENI/deletion contract is in the VPC-delete and EKS network-requirement docs,
  not the EKS cluster resource page.
- E2 — the resource is `google_service_networking_connection`, and ABANDON *keeps* the
  peering (blocking network deletion) rather than bypassing a lock.

**Refuted claim (the defect itself)**

- B2 — the cited sources contradict it; it is the basis of INFRA-045.

**Already-recorded gaps (no duplicate ticket)**

- G2 — Cloud DNS solver not implemented; `gcp-bootstrap-inventory.md` remaining gap #1.
- INFRA-042 — partially-installed GCP platform not destroyable.

**Qualification gaps to record in the matrix / inventory, not tickets**

- The GCP provisioner's live IAM-path boundary demonstration (make INFRA-045's claim
  falsifiable) — belongs to the GCP lifecycle qualification.
- The service-networking ABANDON upper bound (GCP Attempt 3 qualified one observation).
- Finalizer/partial-install timeout and recovery under Terraform orchestration (H1).
- Cross-provider StorageClass/stateful-workload portability (I1).

---

## 4. Sources (fetched and read 2026-09-19)

| Claim | URL |
|---|---|
| A1 | https://docs.aws.amazon.com/eks/latest/best-practices/cluster-access-management.html |
| A2, F1 | `hashicorp/terraform-provider-aws` `website/docs/r/eks_cluster.html.markdown` (renders at https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) |
| B1 | https://cloud.google.com/iam/docs/service-account-overview |
| B2 | https://cloud.google.com/kubernetes-engine/docs/how-to/api-server-authentication ; https://cloud.google.com/kubernetes-engine/docs/how-to/role-based-access-control ; https://cloud.google.com/iam/docs/roles-permissions/container |
| C1 | https://docs.aws.amazon.com/cli/latest/reference/eks/update-kubeconfig.html |
| C2 | https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl |
| D1 | `terraform-provider-aws` `website/docs/r/db_instance.html.markdown`, `rds_cluster.html.markdown` |
| D2 | https://docs.aws.amazon.com/vpc/latest/userguide/delete-vpc.html ; https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html |
| E1 | `terraform-provider-google` `website/docs/r/sql_database_instance.html.markdown` (the `google` provider page; Gemini cited the `google-beta` registry URL, which renders the same resource doc) |
| E2 | `terraform-provider-google` `website/docs/r/service_networking_connection.html.markdown` and `.../service_networking_vpc_service_controls.html.markdown` |
| G1 | https://cert-manager.io/docs/configuration/acme/dns01/route53/ |
| G2 | https://cert-manager.io/docs/reference/api-docs/ |
| F1 (backdrop) | Terraform docs, "Resource Graph" (`internals/graph`) and "Resource Dependencies" (`language/resources/behavior`) |
| Module defaults | `terraform-aws-modules/terraform-aws-eks` v20.8.0 / v20.24.0 / v20.31.6 (README, `main.tf`); `terraform-aws-modules/terraform-aws-iam` v5.39.0 (`modules/iam-role-for-service-accounts-eks/main.tf`) |

**Limitation.** Provider docs are versioned and these were read at their current
`latest`; a provider upgrade can move a default. Each Sol reference above was read in
the working tree at `main @ 7ea2ef43`.

---

## 5. Where these conclusions live now

This report is the dated reconciliation. Its durable, independently referenceable
conclusions were carried into the audit structure on 2026-09-19:

| Conclusion | Durable artifact |
|---|---|
| GCP provisioner IAM grants Kubernetes authority | `findings/FND-0001-...md` → ticket `INFRA-045` (`OPEN`) |
| AWS provisioner can re-grant cluster-admin via the EKS API (found in the follow-up authority audit) | `findings/FND-0002-...md` (`DESIGN_GAP`; no ticket — needs a decision) |
| Authority/absence effective-capability qualification | `findings/FND-0003-...md` |
| GCP partial-install destruction | `findings/FND-0004-...md` → ticket `INFRA-042` (DONE; `FIXED_UNQUALIFIED`) |
| Service-networking ABANDON documented-vs-observed | `findings/FND-0005-...md` (observed twice, Attempts 3 and 4) |
| Retention live postcondition | `findings/FND-0006-...md` → ticket `INFRA-041` (DONE; `QUALIFIED` by Run 7) |
| GCP Cloud DNS / cert-manager capability gap | `findings/FND-0007-...md` (`BLOCKED` on a delegated hostname) |
| AWS runtime Secret identity | `findings/FND-0008-...md` → ticket `INFRA-040` (READY for its diagnostics item; identity `QUALIFIED` by Run 7) |
| Provider substrate/prerequisite differences | `findings/FND-0009-...md` |

The provider-neutral properties behind them are in
`invariants/PROVIDER-NEUTRAL-INVARIANTS.md`, and the compact roll-up is
`QUALIFICATION_STATUS.md`. The externally supplied packet that prompted this pass
is preserved (with provenance) at
`research/aws-gcp-harden-research_gemini-external.md`.

---

## 6. Reconciliation (2026-09-19, later the same day)

This report was reconciled against `origin/main` after #362/#363/#364 merged and
after HARDEN Run 7 and GCP Attempt 4. The dated claims and primary-source
conclusions above are unchanged; the *state* of the findings they produced has
moved, and one issue id was reassigned:

- Ticket **`INFRA-043` was claimed on `origin/main`** by HARDEN Run 7 for a
  different defect (the deploy identity cannot create the boundary lease). This
  report's GCP-IAM ticket is therefore renumbered **`INFRA-045`**.
- `INFRA-042` is `DONE`. INFRA-041's live retention row and INFRA-040's Secret
  identity are behaviourally qualified by Run 7. Attempt 4 fixed a GCP
  absence-recognition defect and exercised the partial-install destroy.
- Findings now carry two axes (classification + state); the authoritative current
  values are in each `findings/FND-*.md` header and in `QUALIFICATION_STATUS.md`.
