---
id: FEAT-007
type: feature
severity: medium
source: PRODUCT_ARCHITECTURE.md
branch: FEAT-007/self-hosted-substrate-contract
worktree: ../sun-FEAT-007-self-hosted-substrate-contract
---

Define the self-hosted substrate contract without rebuilding Terraform.

**Depends on:** FEAT-005.

**Problem:** Sun should let users host on their own infrastructure, but it should not become a general-purpose cloud provisioner. The repo has Terraform modules, but the product boundary is not explicit: Sun needs certain substrate capabilities, while Terraform or cloud tooling should create them.

**Goal:** Document and encode the minimum contract a self-hosted environment must provide for Sun deployment.

**Remediation:**

1. Add a self-hosted substrate contract document under `platform/infra/` or `docs/`.
2. Define required inputs:
   - reachable Kubernetes cluster/context
   - container registry prefix
   - Kafka brokers and schema registry
   - Postgres connection secret/ref
   - observability endpoints
   - optional base domain/TLS ingress
3. Define what Sun generates:
   - namespaces
   - service accounts
   - config/secrets refs
   - deployments/services/cronjobs/ingress/network policies
4. Define what Sun does not generate:
   - VPCs
   - IAM
   - managed databases
   - managed Kafka clusters
   - DNS zones
   - billing/cloud accounts
5. Align README/TUTORIAL language so Terraform is presented as one substrate setup option, not the core Sun deployment engine.

**Out of scope:**

- Changing Terraform modules.
- Building `sun cloud init`.
- Provider-specific automation.

**Acceptance criteria:**

- A user can tell exactly what they must bring for self-hosted mode.
- Docs make clear that generated manifests are Sun's artifact, while cloud substrate remains owned by Terraform/Pulumi/cloud tooling.
- No normal workflow requires hand-written per-service Kubernetes manifests.

**Decisions:**

- Terraform wrappers are a separate milestone after the substrate contract is stable. Write the contract doc first.
- Document generic Kubernetes first, with k3d as the local example. AWS EKS and GCP GKE are substrate details that layer on top.

## Review — automated checks passed
FEAT-007 implemented correctly. Created docs/self-hosted-substrate-contract.md with all required sections: What You Bring (cluster/context, registry prefix, Kafka brokers and schema registry, Postgres connection secret, Loki/Pushgateway endpoints, optional base domain/TLS), What Sun Generates (namespaces, service accounts, configmaps, secret refs, Deployments/Services/CronJobs/Ingress/NetworkPolicies), What Sun Does Not Generate (VPCs, IAM, managed databases, managed Kafka, DNS zones, TLS certificates), Setup Options (k3d, Terraform modules in platform/infra/, Pulumi/CloudFormation, manual), and Deployment Flow. Added Sun_cli_env_target.validate : t -> (unit, string) result that enforces the registry constraint for Customer_k8s_direct and Customer_k8s_gitops modes. cmd_deploy.ml calls validate and exits 1 with a clear error on failure. 5 new tests in test_env_target.ml cover all four validate paths including whitespace-only registry edge case. All pre-commit hooks pass.
