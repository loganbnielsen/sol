# GCP bootstrap inventory and lifecycle proposal

**Inventory date:** 2026-09-18 (America/Denver)

**Project:** `sol-qualification` (project number verified against the supplied
value)

**Scope:** read-only bootstrap qualification; no APIs, IAM, billing, DNS, or
infrastructure were changed.

## Result

The project is not ready for a live Sol qualification. Billing is not linked,
the required infrastructure APIs are disabled, exact quotas therefore cannot
be read, and no qualification service accounts exist. The bootstrap user has
project Owner, so project IAM and API enablement authority are available, but
access to a billing account is a separate prerequisite.

Do not implement the current `cli/platform/infra/gcp` root as-is. It predates
Sol's qualified lifecycle and does not meet the current production contract:

- `sol cloud` deliberately fails closed for GCP and its output contract is
  AWS-specific.
- the root creates GKE Autopilot, while the `node-failure-tolerant` production
  tier requires qualified capacity and explicit node-failure headroom that the
  current root cannot declare or prove;
- Cloud SQL defaults to zonal rather than required regional HA;
- the platform root defaults to the AWS `gp3` StorageClass contract;
- both cert-manager `ClusterIssuer` resources are hard-wired to Route 53
  DNS-01 and cannot issue on GCP as written;
- GCS-backed Loki/Thanos resources exist, but the platform charts are still
  wired for S3 and reject durable GCP observability; and
- DNS creates a zone but no application or wildcard record.

These are implementation gaps, not bootstrap-project defects.

## Read-only inventory

### Principal, project, and Terraform authentication

| Check | Observed | Verdict |
| --- | --- | --- |
| Active gcloud principal | `lbendtlynielsen@gmail.com` | usable bootstrap user |
| Active gcloud project | `sol-qualification` | correct |
| Project lifecycle | `ACTIVE`; created `2026-09-19T04:36:38.151Z` | correct |
| Resource ancestry | project only; no folder or organization returned | no inherited org/folder IAM was visible |
| Local ADC | `authorized_user`, quota project `sol-qualification`; access-token mint succeeded | usable by the Google Terraform provider |
| Terraform | `1.9.8` | satisfies the GCP root's `>= 1.6` constraint |
| Long-lived keys | none created or downloaded | required posture |

Google recommends ADC for Terraform and supports ADC backed by service-account
impersonation. Bootstrap may use the current user ADC; routine Terraform should
impersonate the provisioner service account with short-lived credentials.

### Billing

`billingEnabled` is `false` and `billingAccountName` is empty. This blocks the
billable qualification infrastructure; some API activation can still occur
without billing, but it would not make the target provisionable. Project Owner
does not imply permission to attach an arbitrary billing account; the operator
also needs suitable authority on the selected billing account.

### APIs

Currently enabled:

```text
analyticshub.googleapis.com
bigquery.googleapis.com
bigqueryconnection.googleapis.com
bigquerydatapolicy.googleapis.com
bigquerydatatransfer.googleapis.com
bigquerymigration.googleapis.com
bigqueryreservation.googleapis.com
bigquerystorage.googleapis.com
cloudapis.googleapis.com
cloudtrace.googleapis.com
dataform.googleapis.com
dataplex.googleapis.com
datastore.googleapis.com
logging.googleapis.com
monitoring.googleapis.com
servicemanagement.googleapis.com
serviceusage.googleapis.com
sql-component.googleapis.com
storage-api.googleapis.com
storage-component.googleapis.com
storage.googleapis.com
telemetry.googleapis.com
```

Minimum APIs for the proposed substrate, to enable only after approval:

| API | Why |
| --- | --- |
| `compute.googleapis.com` | VPC, subnets, private service access, GKE nodes, disks, addresses, and load balancers |
| `container.googleapis.com` | GKE |
| `artifactregistry.googleapis.com` | Docker repository |
| `sqladmin.googleapis.com` | Cloud SQL PostgreSQL |
| `servicenetworking.googleapis.com` | private Cloud SQL service connection |
| `dns.googleapis.com` | only if Sol owns a Cloud DNS zone |
| `iam.googleapis.com` | service accounts and IAM bindings |
| `iamcredentials.googleapis.com` | service-account impersonation and linked GKE workload identities |
| `sts.googleapis.com` | external Workload Identity Federation for CI/operator automation |
| `storage.googleapis.com` | already enabled; remote state and durable telemetry objects |
| `logging.googleapis.com`, `monitoring.googleapis.com` | already enabled; provider/GKE telemetry |

`cloudresourcemanager.googleapis.com` and `serviceusage.googleapis.com` are also
bootstrap dependencies. Secret Manager and Cloud KMS are optional choices, not
requirements of the current Sol contract; enable them only if the implementation
actually adopts them.

### IAM and bootstrap capability

The project policy has one binding:

```text
user:LBendtlyNielsen@gmail.com -> roles/owner
```

No user-managed service accounts exist. Project Owner provides broad project
resource/IAM authority, including the ability to establish narrowly scoped
runtime identities. It does not prove billing-account authority, domain/DNS
authority, organization-policy authority, or permissions inherited through an
organization. The final bootstrap must test those separately rather than infer
them from Owner.

### Existing relevant resources

- Cloud Storage enumeration succeeded and returned no buckets.
- No user-managed service accounts exist.
- Compute Engine, GKE, Artifact Registry, Cloud SQL, and Cloud DNS cannot be
  enumerated while their APIs are disabled. Their inventories are therefore
  **unknown**, not confirmed empty.
- Cloud Asset Inventory was not enabled, so no shadow inventory was attempted.

Immediately after the approved API-enable step, repeat all resource queries
before the first Terraform plan. A supposedly disposable project must still
fail closed on unexpected pre-existing resources or name collisions.

### Candidate region

Use `us-central1` as the first qualification candidate: it is the repository's
current GCP default and keeps GKE, Artifact Registry, Cloud SQL, and GCS regional
placement aligned. Keep `us-east1` and `us-west1` as alternatives only if
latency, availability, or quota checks favor them. Do not select a final region
until billing is attached and regional quotas plus required GKE/Cloud SQL
features are queryable.

This is a qualification choice, not a new cross-region abstraction. One region
is enough for `production-single-region/v1`.

### Quotas and blockers

Exact quota limits and usage could not be obtained because billing and the
Compute, GKE, Artifact Registry, Cloud SQL, and DNS APIs are disabled. Validate
at least the following after API activation and before apply:

| Area | Qualification check |
| --- | --- |
| GKE | regional cluster/control-plane limits; Standard node count; Pods; total/SSD persistent-disk capacity |
| Compute | regional CPUs for the chosen machine family; instance groups; routes; forwarding rules; regional/static addresses; health checks; backend services |
| Network | VPCs, subnets, alias IP ranges, routers, Cloud NAT gateways/IPs, firewall rules, private-service-access peering ranges |
| Storage | GCS buckets and request quotas; regional persistent-disk capacity and snapshots |
| Load balancer | forwarding rules, target proxies, URL maps, backend services, health checks, and external IPv4 addresses |
| Cloud SQL | regional instances, CPUs, SSD storage, connections, and private-service networking |
| Artifact Registry | repositories and storage/request quota |

Current hard blockers are unlinked billing, disabled APIs, unread quotas, and
the Sol implementation gaps listed above. A new project may also start with
low CPU/address quotas; do not treat a successful API enable as capacity proof.

### Artifact Registry prerequisites

Required: billing, Artifact Registry API, a regional Docker repository, a
publisher with repository-scoped `roles/artifactregistry.writer`, and a pull
identity with `roles/artifactregistry.reader` if same-project GKE defaults do
not already cover the selected node identity. CI should authenticate through
Workload Identity Federation and service-account impersonation; interactive
qualification may use a short-lived gcloud access token or credential helper.
No JSON service-account key is needed.

Sol must continue deploying immutable digests. Repository creation/lifecycle is
provisioner authority; pushing or replacing image content is publisher
authority.

### DNS and TLS prerequisites

GCP does not require Cloud DNS if an existing provider can create records for
the chosen base domain. When qualification includes a workload with
`ingress_host` and TLS issuance, Sol requires:

- control of a qualification subdomain;
- either delegated Cloud DNS nameservers or an external DNS operator;
- an A/AAAA or CNAME record strategy from application/wildcard names to the
  ingress load-balancer address; and
- a publicly resolvable hostname and Let's Encrypt contact email for the
  cert-manager `ClusterIssuer` path; and
- replacement of the current Route 53 DNS-01 solver with a qualified Cloud DNS
  solver and scoped workload identity, or a solver for the chosen external DNS
  provider.

No zone, delegation, record, or certificate was changed. Zone creation alone
is insufficient: registrar delegation and ingress records remain explicit
operator prerequisites. Google-managed certificates are not an automatic
replacement for Sol's current cert-manager contract.

### GKE Workload Identity Federation prerequisites

Workload Identity Federation for GKE is always enabled on Autopilot. If the
production contract selects GKE Standard for fixed capacity/headroom, enable it
on the cluster and node pools. In either mode:

- enable IAM Service Account Credentials;
- grant each Kubernetes service account only the target API permissions it
  needs, preferably directly to its workload principal;
- use a linked Google service account only where an API/tool requires service
  account semantics; and
- preserve Sol's default of no ambient Kubernetes token for workloads that do
  not need Kubernetes API access.

The existing GCP root's Loki/Thanos service-account bindings are a valid
starting mechanism, but they are not complete until the platform charts use
GCS and the live workload principal is verified.

### Organization policies and project constraints

Project ancestry returned only the project. The Organization Policy API is
disabled, so effective constraints could not be enumerated without mutation.
Before provisioning, enable/read it with approval and check at least service
account key creation, allowed regions, external IPs, VPC peering, public load
balancers, uniform bucket access, domain-restricted sharing, and required CMEK.

The proposed design already avoids service-account keys. Any stronger policy
must be treated as an input to Terraform/preflight, not bypassed.

## Three kinds of prerequisite

### Objectively required by GCP

- linked billing for billable services;
- enabled service APIs;
- sufficient regional/global quota;
- non-overlapping VPC, Pod, Service, control-plane, and private-service-access
  CIDRs;
- IAM permissions to create/use each resource and impersonated identity;
- GKE authentication plus Kubernetes authorization;
- Artifact Registry authentication/authorization; and
- DNS authority only if the chosen implementation uses Cloud DNS.

### Required by Sol's current production contract

- encrypted, versioned, locked remote Terraform state recoverable by a clean
  runner, with separate cloud and platform state objects;
- named, scoped provisioner, publisher, deployer, and operator semantic
  authorities distinct from a standing cluster-creator admin;
- qualified capacity and explicit node-failure headroom when a workload selects
  the `node-failure-tolerant` tier;
- a privileged platform-install window through verified readiness, followed by
  a non-escalatable steady-state provisioner;
- Cloud SQL regional HA, PITR, deletion protection during `Ready`, and a
  rehearsed restore path when Postgres is used; the live guarantee requires
  Cloud SQL's API-level deletion protection, not only Terraform's provider-side
  `deletion_protection` guard;
- immutable image digests;
- cert-manager, ingress, storage, Redpanda, Argo CD, and observability readiness
  predicates equivalent to the qualified AWS contract;
- control of a qualification hostname, DNS reachability, and public CA issuance
  when qualifying a workload's public-ingress/cert-manager capability;
- a configured and actually delivered/acknowledged alert receiver; and
- resumable destruction from every phase that may contain infrastructure; and
- **nothing normal Sol operation creates may make a disposable target impossible
  to destroy through the documented lifecycle**, with a disposable qualification
  target able to reach literal `Absent`. Discovered on AWS (HARDEN-002 attempt 5:
  an ECR repository, plus `prevent_destroy` telemetry buckets that made *every*
  destroy of a durable-observability target impossible). Applied to both
  providers and asserted structurally, because GCS telemetry, artifact and state
  buckets are the same class of trap — an artifact of normal operation cannot be
  what makes the qualification environment immortal.

### AWS assumptions not to carry into GCP

- four AWS roles mapping one-to-one to four Google service accounts;
- ARN, STS AssumeRole, IRSA, EKS access-entry, or managed EKS access-policy
  vocabulary;
- S3 plus DynamoDB for state locking;
- ECR repository/login mechanics;
- Route 53 ownership of DNS;
- EBS CSI and a `gp3` StorageClass;
- ALB hostname behavior;
- RDS final-snapshot mechanics or identifier rules;
- CloudWatch dashboards as the managed-resource observability contract; and
- EKS managed-node-group/AZ behavior as proof that GKE Autopilot or Standard
  satisfies Sol capacity and failure tests.

## Proposed GCP capability mapping

Do not create a generic identity abstraction or force the AWS count. Preserve
semantic boundaries and use the fewest principals that enforce them.

| Sol capability | Proposed GCP implementation |
| --- | --- |
| Bootstrap authority | Temporary human/group authority for approved project bootstrap. The current Owner can serve for qualification, then becomes break-glass rather than the routine operator credential. No standing cluster admin. |
| Operator authority | Bounded identity for supported day-to-day operations, with impersonation only of a dedicated operator service account if one is needed. Destructive lifecycle approval uses the separate bootstrap/destroy authority. GCP IAM cannot restrict Token Creator to a Sol command or phase, so anyone allowed to impersonate a stronger identity is honestly treated as holding that identity's full authority. |
| Provisioner | One user-managed service account impersonated only by approved bootstrap/provisioning automation. Give it the minimum GCP roles for the cloud root and explicit Kubernetes RBAC for the platform root. Temporarily grant installation authority only during `PlatformInstalling`/`PlatformUpdating`; revoke and verify it before `Ready`. Splitting cloud and platform provisioners is unnecessary until trust owners differ. |
| Publisher | Repository-scoped service account with Artifact Registry writer only. CI obtains it through external Workload Identity Federation; humans may impersonate it for qualification. |
| Deployer | Identity authorized to fetch GKE credentials plus Sol's namespace-scoped deploy RBAC, but unable to push images or provision infrastructure. CI may use the same external identity provider as publisher while impersonating a different service account for each operation. |
| Workload identity | Workload Identity Federation for GKE, direct principal IAM grants where supported; linked Google service accounts only for APIs/tools requiring them. |
| Remote Terraform state | Dedicated GCS bucket with uniform access, versioning, encryption, public-access prevention, and native backend locking. Use deterministic `sol/<target>/cloud.tfstate` and `sol/<target>/platform.tfstate` prefixes. Bootstrap state remains the unavoidable separate bootstrap boundary. |
| Kubernetes access | Ephemeral kubeconfig from `gcloud container clusters get-credentials`, isolated per phase. IAM establishes cluster discovery/credential access; Kubernetes RBAC establishes Sol authority. Never use ambient kubeconfig. |
| Database | Private-IP Cloud SQL for PostgreSQL 16, regional HA, PITR/backups, API-level `settings.deletion_protection_enabled` in `Ready`, and an explicit destroy preparation. Terraform's top-level `deletion_protection` is a useful second guard but is not the live GCP protection predicate. Keep credentials out of plans/logs; choose password rotation or IAM database authentication deliberately during implementation. |
| Registry | Regional Artifact Registry Docker repository, digest deployment, repository-scoped writer/reader permissions. |
| DNS/TLS | Conditional on workloads declaring `ingress_host`. Use Cloud DNS only when Sol is delegated the qualification zone; otherwise consume operator-managed records. Keep ingress-nginx plus cert-manager/ACME for contract parity, but replace the hard-coded Route 53 DNS-01 solver with Cloud DNS plus a scoped GKE workload identity, or with the selected external provider's qualified solver before TLS capability qualification. |
| Observability/storage | GKE persistent disks through a GCP StorageClass; GCS for durable Loki/Thanos after completing the existing chart wiring; Cloud Logging/Monitoring for GCP/GKE control-plane signals, not as an unqualified replacement for Sol's platform observability. |

GCS backend locking is native; do not add a lock database. Terraform remains
authoritative for its own resources and dependency graph. Sol only sequences
the two roots, validates their typed outputs, applies phase policy, and verifies
live postconditions.

## Provider-neutral lifecycle on GCP

Every operation re-derives progress from Terraform state and live GCP/GKE
observations. No persisted Sol phase pointer and no second resource-level DAG
is introduced.

| Transition | Required authority | GCP mechanism | Preconditions | Verified postconditions | Recovery/idempotency |
| --- | --- | --- | --- | --- | --- |
| `Absent -> CloudBootstrap` | approved bootstrap authority using user ADC | enable the approved API set; create GCS state facility and scoped identities/WIF; then use impersonation | correct project/number; billing already linked by an authorized account operator; no conflicting resources; readable constraints; no service-account keys | remote state is versioned/encrypted/locked; identities can be impersonated; required APIs and quota are present | bootstrap resources have deterministic names and import/reconcile cleanly; re-run observes existing state rather than recreating it |
| `CloudBootstrap -> PlatformInstalling` | impersonated provisioner plus temporary installation authority | cloud-root Terraform creates VPC/private service access, GKE, Artifact Registry, Cloud SQL, storage and optional DNS; Sol reads typed outputs, writes an ephemeral kubeconfig, and opens the bounded privileged install window | initialized cloud state; valid CIDRs/quotas; required secrets and DNS decision; provider output contract | cloud root applies; GKE/API reachable as the named provisioner; database/registry/network outputs validate; install authority is effective | re-run the same cloud root; Terraform reconciles partial resources; later platform plan remains `Deferred` until outputs/access exist |
| `PlatformInstalling -> Ready` | provisioner with temporary cluster-install privilege | staged platform-root Terraform: cert-manager first, verify CRDs, then remaining charts/RBAC/storage; revoke installation grant after live readiness | cluster reachable; cloud outputs valid; platform backend initialized | Kubernetes-native convergence passes; ingress has an address; GCP StorageClass works; bounded provisioner positive permissions pass and `escalate`/`bind` fail; temporary privilege is gone. External ACME/issuer readiness does not gate this transition; actual TLS issuance is qualified separately when used. | repeat incomplete Terraform stages and readiness checks; do not de-escalate early; failed install remains destructible |
| `Ready -> PreparingDestroy` | approved bootstrap/destroy authority impersonating the provisioner | apply Destroy policy through Terraform: disable both Cloud SQL API-level and Terraform-side deletion protection; establish final-backup behavior; explicitly retain/adopt or empty and unprotect durable telemetry buckets; stop applying Production policy | target may be Ready or any infrastructure-bearing partial phase; backend/state accessible; retention/destruction choice approved | Cloud SQL API protection is observably disabled; bucket retention/unprotect state is verified; final-backup inputs are valid if required; no subsequent Ready policy runs | safe to repeat; an interrupted preparation remains in Destroy policy and resumes destruction; `PreparingDestroy -> Ready` is illegal |
| `PreparingDestroy -> Destroying` | bootstrap/destroy authority | destroy platform root, then cloud root, in reverse semantic dependency order | preparation verified; state locks obtainable; durable buckets are either adopted outside the target root or explicitly empty/unprotected; no Ready reconciliation | platform resources absent before GKE/network dependencies; cloud destruction underway/complete; retained backups/storage/state are reported | repeat `terraform destroy`; missing resources are no-ops; refresh/import repair handles drift; never hand-build a resource deletion DAG in Sol |
| `Destroying -> Absent` | destroy authority for verification; state operator for approved cleanup policy | live absence checks for GKE, SQL, registry, network/LB/storage/DNS resources; retain or separately retire the bootstrap/state facility per policy | both root destroys completed or are resumable | all target-owned runtime resources absent; no temporary IAM/install grants; retained state/backups are named; destroy of an already absent target succeeds | re-run verification/destroy until absent; keep state versions for recovery/audit; bootstrap facility cleanup is a separate explicit operation |

Destruction remains an abort edge from `CloudBootstrap`,
`PlatformInstalling`, `Ready`, and any interrupted destroy phase. A privileged
platform update after `Ready` similarly uses the existing provider-neutral
`PlatformUpdating` re-entry even though it is not part of the abbreviated
qualification sequence above.

## Approval gates before implementation

1. Link billing and confirm the bootstrap operator can use the selected billing
   account.
2. Approve the minimum API list, then repeat inventory, effective-policy, and
   quota checks.
3. For qualification of `node-failure-tolerant`, choose GKE Standard or define
   and prove how Autopilot supplies the contract's declared failure headroom;
   the current root provides no such evidence.
4. Supply a qualification subdomain/delegation strategy and Let's Encrypt
   contact without changing DNS yet; select and wire a non-Route-53 cert-manager
   solver before qualifying a workload that uses public TLS.
5. Decide Cloud SQL credential handling and destroy/final-backup semantics.
6. Decide whether durable telemetry buckets are retained or explicitly emptied
   during approved destruction; the current `prevent_destroy = true` resources
   cannot participate in a complete target destroy as written.
7. Implement the GCP cloud output contract and GCS observability/storage wiring,
   then qualify through the public `sol cloud` lifecycle rather than a shadow
   Terraform/Helm harness.

## Implementation progress

**Updated:** 2026-09-18 (America/Denver). Read-only re-check of the bootstrap
prerequisites. No resource, API, IAM, billing, DNS, or infrastructure change was
made or left behind.

### Preflight re-check

| Check | Observed | Verdict |
| --- | --- | --- |
| Active principal | `lbendtlynielsen@gmail.com` | unchanged |
| Active project | `sol-qualification`, number matches the supplied value | unchanged, `ACTIVE` |
| Billing linked | `billingEnabled = false`, `billingAccountName` empty | **blocked** |
| Enabled APIs | the same 22 services listed above, byte for byte | unchanged |
| Project IAM | one binding: `user:LBendtlyNielsen@gmail.com` → `roles/owner` | unchanged |
| User-managed service accounts, GCS buckets | none | unchanged |
| Long-lived service-account keys | none created or downloaded | required posture held |

Two billing accounts are visible to this principal, one open and one closed. The
open one is the candidate; neither is named here, for the same reason the rest of
this file names no account-level identifier.

**The blocker is stronger than the original inventory implied, and that changes
what "prerequisite" means here.** Unlinked billing does not merely block the
billable qualification resources — it blocks the *bootstrap* step:

```text
ERROR: (gcloud.services.enable) FAILED_PRECONDITION: Billing account for project
'<project-number>' is not found. Billing must be enabled for activation of
service(s) 'artifactregistry.googleapis.com, compute.googleapis.com,
container.googleapis.com, dns.googleapis.com,
containerregistry.googleapis.com' to proceed.
  reason: UREQ_PROJECT_BILLING_NOT_FOUND
```

So the API-enable step in the lifecycle table (`Absent -> CloudBootstrap`) is
itself gated, and the "repeat all resource queries before the first Terraform
plan" instruction above is not reachable. Quota, capacity, and the inventories
that need Compute/GKE/Cloud SQL/DNS APIs stay **unknown**, not empty. The refused
enable left the project untouched — the enabled-service list is identical to the
one recorded above.

**Action required, and only this: link an open billing account to
`sol-qualification`.** That is an account-level relationship outside Sol's
project-scoped bootstrap authority, and this work is not authorized to change it.
Everything else in the preflight is ready: principal, project, ADC, Terraform, and
the Owner binding that can create the qualification-scoped identities and
resources. Once billing is linked, the next attempt resumes at the API-enable
step.

### Code landed without a live project

Three changes address gaps 1, 2 and the retained-storage half of gap 5 below. All
are validated offline only — static/configuration and mechanism/renderability
evidence, not behavioural evidence — and the first two are not yet reachable on
GCP, because the GCP lifecycle still fails closed in `sol cloud`.

- **Provider-specific Kubernetes storage and readiness.** `Ready` asserted `gp3`
  and `ebs.csi.aws.com` literally in a module that is meant to be
  provider-neutral. The provider's storage facts are now data
  (`Sol_cli_cloud_lifecycle.platform_storage`), the check asserts the provider's
  class is the *sole* default and is backed by the provider's block-storage CSI
  driver, and the AWS guarantee is unchanged. EKS ships no default class so Sol
  creates one; GKE ships `standard-rwo` already defaulted, so Sol adopts it —
  creating a second default class would leave the cluster with two, which
  Kubernetes resolves arbitrarily.
- **Provider-selected remote state and platform roots.** `backend_config` is
  provider-aware (S3 + DynamoDB locking, GCS with native locking), the cloud
  target no longer requires an AWS role ARN of a GCP target, and
  `cli/platform/infra/base-gcp` is a GCP platform root declaring the GCS backend
  and calling the shared platform definition as a module.
- **A disposable target must be able to reach `Absent`** (carried forward from AWS
  HARDEN-002 attempt 5, and deliberately applied to the invariant rather than to
  the AWS resource that exposed it). `prevent_destroy` is gone from both providers'
  durable telemetry buckets; deletability is wired to
  `durable_storage_force_destroy`, whose default keeps a direct `terraform
  destroy` conservative while the Destroy policy names the decision to discard the
  target's telemetry. GCS telemetry, artifact and state buckets are the same class
  of trap, so the guard is over the roots rather than over the two known buckets:
  a third durable resource cannot reintroduce it.

The Destroy policy also became provider-shaped in the same change. It was
returning `rds_deletion_protection`, `rds_skip_final_snapshot` and
`rds_final_snapshot_identifier` for *every* provider, which the GCP root does not
declare — so a GCP destroy would have failed on an undeclared variable the moment
the GCP path opened. The neutral part is that a Destroy policy exists and the
phase names it; the levers are the provider's.

### Structural finding: a Terraform root cannot carry two backends

This is the first case where the provider-neutral model had to change rather than
gain a branch. A backend's *type* is part of a Terraform root's own
configuration — `-backend-config` sets attributes, never the type — so a single
platform root cannot serve S3 state for AWS and GCS state for GCP. The
resolutions considered:

1. **Per-provider roots over a shared definition** (chosen). The definition stays
   where it is and each provider's root supplies only what a root can. A module's
   own `terraform` block is ignored with a warning, which is what makes this work
   without moving 1,500 lines.
2. **Extract the definition into its own module** and make both providers' roots
   thin wrappers. Cleaner and symmetric, but it changes every AWS resource address
   (`module.platform.*`) on a path that is live-qualified — churn without evidence
   to justify it today. This remains the better long-term shape and is the natural
   follow-up once the GCP path is qualified.
3. **One backend type for both providers.** Rejected: it would change AWS's state
   contract (S3 + DynamoDB locking is a named requirement) to accommodate GCP.
4. **S3-compatible access to GCS** (`endpoints { s3 = ... }` plus HMAC keys).
   Rejected: it requires long-lived credentials, which the posture above forbids.

The mirroring in option 1 introduces one liability — a variable added to the
definition and forgotten in the GCP root — so
`cli/sol/test/check_production_infra.sh` now fails if the wrapper does not mirror
every declared variable except the AWS-only ones, and fails if it declares one the
definition does not.

### Remaining gaps

Ordered by what unblocks the next one; all still open.

1. **GCP cert-manager solver and Workload Identity wiring.** The shared
   definition's `ClusterIssuer`s are hard-wired to the Route 53 DNS-01 solver, so
   a GCP install cannot issue a certificate as written. Needs a Cloud DNS (or
   operator-supplied external DNS) solver plus scoped Workload Identity, and a
   real TLS qualification is additionally blocked on a delegated qualification
   hostname.
2. **Typed GCP cloud outputs and platform input mapping.** `aws_outputs_of_json`
   and `platform_terraform_vars` are AWS-shaped; GCP needs its own typed outputs
   (project, region, cluster, Workload Identity identities, GCS buckets) and a
   mapping that selects `cloud_provider = "gcp"` and the GCS variable set.
3. **GCP kubeconfig and scoped authority.** Ephemeral credentials from
   `gcloud container clusters get-credentials`, the provisioner service account,
   the `PlatformInstalling` privileged window, and the positive/negative
   `can-i` probes.
4. **Provider-neutral `sol cloud` plan/apply/destroy for GCP.** The outer gate
   that refuses GCP, the GCP variant of cloud-ready observation, and the platform
   targets addressing `module.platform.*`.
5. **GCP destruction preparation.** Cloud SQL API-level deletion protection off by
   an applied transition, and a per-attempt backup identity that the qualification
   path does *not* leave behind: a disposable target must reach literal `Absent`,
   so taking a final backup and retaining it is the production behaviour, and
   qualification either skips it or removes it before declaring absence.
   The retained-storage half of this gap is **closed** for both providers: the
   `prevent_destroy` buckets are gone, deletion is wired to
   `durable_storage_force_destroy`, and the Destroy policy names the decision.
6. **Cloud SQL regional HA for the production profile**, and the production
   profile's capacity contract proven on the selected GKE mode (the current root
   is Autopilot, which cannot declare the `node-failure-tolerant` headroom).
7. **GCS durable-observability chart wiring** — the Loki/Thanos values are still
   S3-shaped and `OBS-034`'s gate still rejects `gcp + self_hosted_durable`
   (INFRA-005).
8. **Offline qualification/preflight coverage** for the GCP path, and a GCP
   counterpart to `production-single-region-v1-matrix.md`.

## References

- [Terraform authentication on Google Cloud](https://cloud.google.com/docs/terraform/authentication)
- [Workload Identity Federation for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [Artifact Registry Docker authentication](https://cloud.google.com/artifact-registry/docs/docker/authentication)
- [Terraform GCS backend](https://developer.hashicorp.com/terraform/language/backend/gcs)
