<!--
================================================================================
EXTERNALLY GENERATED RESEARCH — SOURCE MATERIAL, NOT SOL DOCUMENTATION
================================================================================
Provenance : produced by Gemini Pro (external model) and supplied to the Sol
             repository on 2026-09-19.
Status     : UNVERIFIED at time of writing. This file is an *index of claims*
             into primary sources, not authority. It is known to contain
             citation and contract errors (see below).
Authority  : none. Nothing in this file is a Sol contract, decision, or
             qualification result.
Superseded : for Sol qualification purposes, by the independently verified
             provider-contract reconciliation
             `internal/pipeline/audits/2026-09-19_provider_contract_verification.md`,
             which opens each cited primary source, corrects or discards the
             claims that do not hold, and reconciles them against the current
             Sol implementation and HARDEN evidence. That report is
             authoritative; this packet is not.
Known errors (not corrected here, deliberately — the errors are why independent
verification exists):
  - GKE `roles/container.developer` is described as conferring no Kubernetes
    authority; GKE documentation says the opposite (IAM is an authorization
    fallback). This error is the origin of INFRA-045.
  - Service Networking `deletion_policy = "ABANDON"` is described as
    "bypassing VPC deletion locks"; the provider documents that it removes the
    connection from state and *leaves the peering in place*, and offers
    `REMOVE_PEERING` for teardown.
  - The GKE `gke-gcloud-auth-plugin` 1.26+ requirement is attributed to the
    wrong page, and the AWS VPC/ENI deletion contract to the EKS cluster
    resource page rather than the VPC and EKS network-requirement pages.
Body below is preserved verbatim from the supplied file. Do not edit it to
match current knowledge; correct knowledge belongs in the verified report and
the findings under `internal/pipeline/audits/findings/`.
================================================================================
-->

# EXTERNAL RESEARCH (Gemini Pro, 2026-09-19) — unverified

> This is externally generated source material, preserved for provenance. It is
> not authoritative and must not be cited as a Sol contract. See
> `internal/pipeline/audits/2026-09-19_provider_contract_verification.md` for the
> verified reconciliation.

---

This research packet details the authoritative contracts, documented behaviors, and provider semantics for deploying and destroying cloud infrastructure on AWS and Google Cloud Platform (GCP). It is optimized for downstream static and behavioral auditing.

## Identity and Authority

### AWS Identity and Authority

* **Claim:** For EKS clusters, the `aws-auth` ConfigMap is deprecated in favor of the Cluster Access Management (CAM) API. IAM principals must be granted access via EKS Access Entries, meaning authentication is handled by AWS IAM while authorization is defined by Kubernetes RBAC or EKS-specific Access Policies.
* **Source:** [https://docs.aws.amazon.com/eks/latest/best-practices/cluster-access-management.html](https://docs.aws.amazon.com/eks/latest/best-practices/cluster-access-management.html?utm_source=gemini)
* **Strength:** DOCUMENTED BEHAVIOR
* **Qualification implication:** The implementation's use of CAM vs. ConfigMap can be verified statically offline. However, validating that the external IAM role effectively maps to internal K8s permissions requires a live deployment.


* **Claim:** When an EKS cluster is created, the IAM entity that creates it automatically receives cluster administrator permissions. To prevent this, the cluster configuration must explicitly disable bootstrap creator admin permissions.
* **Source:** [https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster?utm_source=gemini)
* **Strength:** DOCUMENTED CONFIGURATION REQUIREMENT
* **Qualification implication:** Statically verifiable in Terraform configuration. Live testing is needed to ensure the creator identity successfully provisions secondary access mechanisms before it revokes its own bootstrap credentials.



### Google Cloud Identity and Authority

* **Claim:** To let a user or pipeline impersonate a Google service account (to provision infrastructure without downloading JSON keys), the calling principal must be granted the `roles/iam.serviceAccountTokenCreator` role on the target service account.
* **Source:** [https://docs.cloud.google.com/iam/docs/service-account-overview](https://docs.cloud.google.com/iam/docs/service-account-overview?utm_source=gemini)
* **Strength:** DOCUMENTED GUARANTEE
* **Qualification implication:** Can be analyzed statically in IAM bindings.


* **Claim:** Possessing Google Cloud IAM roles like `roles/container.developer` provides authentication to the GKE cluster API but does not natively authorize workload deployment. Actual cluster interaction requires Kubernetes RBAC configured for the authenticated Google identity.
* **Source:** [https://docs.cloud.google.com/kubernetes-engine/docs/how-to/api-server-authentication](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/api-server-authentication?utm_source=gemini)
* **Strength:** DOCUMENTED BEHAVIOR
* **Qualification implication:** Validating that an impersonated pipeline account can successfully apply Helm charts or Kubernetes manifests requires live cluster qualification.



---

## Kubernetes Access Tooling

### AWS CLI / kubeconfig

* **Claim:** The `aws eks update-kubeconfig` command appends cluster connection data to the file specified by `--kubeconfig` or the first path in the `$KUBECONFIG` environment variable. It configures `kubectl` to execute the AWS CLI as a credential plugin.
* **Source:** [https://docs.aws.amazon.com/cli/latest/reference/eks/update-kubeconfig.html](https://docs.aws.amazon.com/cli/latest/reference/eks/update-kubeconfig.html?utm_source=gemini)
* **Strength:** DOCUMENTED BEHAVIOR
* **Qualification implication:** A preflight check must verify that the AWS CLI is installed on the host running `kubectl`, and that host environment variables do not override the pipeline's expected `$KUBECONFIG` path.



### GCP CLI / kubeconfig

* **Claim:** `gcloud container clusters get-credentials` updates the kubeconfig file, but starting in GKE v1.26+, `kubectl` will fail to authenticate unless the `gke-gcloud-auth-plugin` binary is installed in the execution environment.
* **Source:** [https://docs.cloud.google.com/kubernetes-engine/docs/how-to/api-server-authentication](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/api-server-authentication?utm_source=gemini)
* **Strength:** DOCUMENTED CONFIGURATION REQUIREMENT
* **Qualification implication:** Preflight host tooling checks must explicitly verify the presence of `gke-gcloud-auth-plugin`, as having only `gcloud` installed is insufficient for platform deployment.



---

## Infrastructure Lifecycle and Destruction

### AWS Destruction

* **Claim:** A Terraform `aws_rds_cluster` or `aws_db_instance` will block destruction and fail unless `skip_final_snapshot` is explicitly set to `true`, or a final snapshot identifier is provided.
* **Source:** [https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster?utm_source=gemini)
* **Strength:** DOCUMENTED CONFIGURATION REQUIREMENT
* **Qualification implication:** Readily validated statically in Terraform code.


* **Claim:** AWS VPC deletion will deadlock if Kubernetes-managed resources (like Load Balancers or node Elastic Network Interfaces) are not completely destroyed first.
* **Source:** [https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster?utm_source=gemini)
* **Strength:** DOCUMENTED BEHAVIOR
* **Qualification implication:** Requires disposable live qualification environments to prove that the platform tooling correctly sweeps and destroys all unmanaged cloud resources (e.g., K8s `Service` load balancers) before triggering the Terraform destroy phase.



### GCP Destruction

* **Claim:** The Google Cloud SQL database instance resource (`google_sql_database_instance`) contains a `deletion_protection` field that defaults to `true`. Terraform is prevented from destroying the database unless this is modified in the state prior to destruction.
* **Source:** [https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/sql_database_instance](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/sql_database_instance?utm_source=gemini)
* **Strength:** DOCUMENTED GUARANTEE
* **Qualification implication:** Can be validated offline statically.


* **Claim:** Service Networking VPC connections can be configured with a Terraform `deletion_policy`. When set to `ABANDON`, Terraform removes the resource from its state file without attempting to delete the underlying API resource, bypassing VPC deletion locks.
* **Source:** [https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_networking_vpc_service_controls](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_networking_vpc_service_controls?utm_source=gemini)
* **Strength:** DOCUMENTED BEHAVIOR
* **Qualification implication:** Strongly requires live qualification testing. Abandoning resources during teardown can leave zombie networks incurring costs, which static analysis cannot prove.



---

## Terraform Semantics

* **Claim:** Terraform destroys resources in reverse dependency order. If the `depends_on` meta-argument is not explicitly defined between an `aws_eks_cluster` and the IAM role policies granting it permissions, Terraform may destroy the EKS IAM permissions before the cluster itself. This leaves the EKS cluster unable to delete its managed EC2 infrastructure (like security groups), resulting in a failed destroy operation.
* **Source:** [https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster?utm_source=gemini)
* **Strength:** DOCUMENTED CONFIGURATION REQUIREMENT
* **Qualification implication:** Statically verifiable by analyzing the Terraform dependency graph.



---

## DNS and Certificates

* **Claim:** To issue DNS-01 certificates on AWS, `cert-manager` must be authorized to mutate Route53. The documented approach utilizes EKS IAM Roles for Service Accounts (IRSA) with a trust policy allowing `sts:AssumeRoleWithWebIdentity` bound directly to the `cert-manager` Kubernetes ServiceAccount.
* **Source:** [https://cert-manager.io/docs/configuration/acme/dns01/route53/](https://cert-manager.io/docs/configuration/acme/dns01/route53/?utm_source=gemini)
* **Strength:** DOCUMENTED CONFIGURATION REQUIREMENT
* **Qualification implication:** Offline analysis can verify the IAM trust policy maps to the correct OIDC provider and K8s namespace.


* **Claim:** `cert-manager` natively supports an `ACMEIssuerDNS01ProviderCloudDNS` solver for Google Cloud DNS.
* **Source:** [https://cert-manager.io/docs/reference/api-docs/](https://cert-manager.io/docs/reference/api-docs/?utm_source=gemini)
* **Strength:** DOCUMENTED CONFIGURATION REQUIREMENT
* **Qualification implication:** End-to-end validation requires live provisioning of authoritative DNS zones.



---

## Kubernetes / Platform Partial Installation

* **Claim:** If a Kubernetes platform installation fails midway, or if Custom Resource Definitions (CRDs) are deleted while Custom Resources (CRs) still exist, Kubernetes finalizers often deadlock resource deletion. Terraform's Kubernetes provider will hang until its timeout is reached when attempting to destroy the stuck resources.
* **Source:** NOT DOCUMENTED / REQUIRES EMPIRICAL VALIDATION (This is standard Kubernetes finalizer mechanics, but exact failure/recovery behavior under Terraform orchestration must be empirically derived).
* **Strength:** NOT DOCUMENTED / REQUIRES EMPIRICAL VALIDATION
* **Qualification implication:** An engineering team must intentionally inject partial failures into a live qualification run to measure timeout durations and validate rollback/teardown resilience.



---

## Storage and Kubernetes Provider Differences

* **Claim:** EKS and GKE ship with differing default StorageClasses, leveraging distinct CSI drivers (`ebs.csi.aws.com` vs. `pd.csi.storage.gke.io`). They do not share identical default behaviors for VolumeBindingMode (e.g., Immediate vs. WaitForFirstConsumer) or cross-zone topologies.
* **Source:** NOT DOCUMENTED / REQUIRES EMPIRICAL VALIDATION (Provider specific driver docs exist, but the portability constraints across standard platform deployments must be manually tested).
* **Strength:** NOT DOCUMENTED / REQUIRES EMPIRICAL VALIDATION
* **Qualification implication:** Do not assume `StorageClass: default` behaves consistently across AWS and GCP. Must be tested against stateful workload deployments in both live environments.



---

## Assumption-Risk Section

The following table summarizes assumptions that are dangerous for an infrastructure platform to make without validation:

| Assumption | Authoritative Documented Behavior | Recommended Check Type |
| --- | --- | --- |
| **CLI tooling is sufficient if `aws` / `gcloud` is present.** | GKE v1.26+ strictly requires the separate `gke-gcloud-auth-plugin` binary to generate tokens for `kubectl`. | **Preflight** against the installed tooling. |
| **Destroying an AWS VPC is guaranteed once subnets are destroyed.** | EKS clusters and load balancers dynamically spawn ENIs that prevent VPC destruction unless explicitly deleted or properly ordered. | **Both** (Statically verify dependencies; live test the deletion sequence). |
| **EKS IAM cluster destruction will succeed automatically.** | EKS requires `depends_on` linking the cluster to its IAM role policies, otherwise permissions are revoked before the cluster cleans up its managed security groups. | **Statically/Offline** via code analysis. |
| **Abandoning GCP Service Networking avoids state deadlocks safely.** | Using `deletion_policy = "ABANDON"` drops the connection from Terraform state but leaves the peering active in GCP. | **Disposable live qualification** to verify it doesn't incur zombie costs or block subsequent VPC deletion. |
| **RDS and CloudSQL can be destroyed transparently.** | Both AWS (`skip_final_snapshot`) and GCP (`deletion_protection`) actively block automated Terraform destruction by default. | **Statically/Offline** via code analysis. |
| **A partially failed K8s chart will cleanly roll back.** | Stuck finalizers on orphaned Custom Resources will cause orchestration tooling (like Terraform's helm/kubernetes providers) to time out rather than fail fast. | **Disposable live qualification** to observe real-world timeout/deadlock behavior. |
| **The identity creating the cluster has permanent admin access.** | In AWS, EKS gives the creating principal bootstrap admin rights, but GCP isolates IAM from internal K8s RBAC bindings. | **Both** (Verify configuration statically; prove access end-to-end live). |
