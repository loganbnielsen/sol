---
id: AUDIT-064
type: audit-finding
severity: high
source: direct AWS account investigation, 2026-09-07 — prompted by a question about whether local port-forward leaks imply broader teardown gaps
---

**Depends on:** None.

`sol cloud destroy` never explicitly deletes `ingress-nginx`'s `LoadBalancer`-type Kubernetes Service (or any other `LoadBalancer` Service) before running `terraform destroy` — the resulting real AWS ELB/NLB is invisible to Terraform's own state and to `verify_aws_destroy`'s post-teardown checks.

**Description:** `platform/infra/base/variables.tf:15` defaults `ingress_service_type` to `LoadBalancer` for real cloud clusters. On EKS this makes the cluster's cloud-controller provision a genuine, billed AWS load balancer that Terraform's state has zero knowledge of — `platform/infra/aws/main.tf` only tracks `helm_release.ingress_nginx`, not what that chart's Service causes AWS to create underneath it. Grepped `platform/infra/aws/scripts/teardown-provisioner.sh` and `cli/sol/bin/cmd_cloud_tf.ml`'s destroy path: neither contains any `helm uninstall`, Service deletion, or ELB/NLB check of any kind. `verify_aws_destroy` (in `cmd_cloud_tf.ml`) only confirms EKS/RDS/ECR are gone after `terraform destroy` — it has no equivalent check for load balancers.

Checked the actual AWS account (`876701109436`, us-east-1) after DOGFOOD-011's real smoke-test run and confirmed **no live ELB/NLB, EKS cluster, RDS instance, non-default VPC, ECR repository, or S3 bucket currently exists** — that specific run's teardown did not leave anything behind. This is reassuring for that one run, but doesn't mean the gap is safe: nothing in the code path explicitly prevents it, and this class of bug is a well-known real-world EKS gotcha (an orphaned ELB's ENI can also block `terraform destroy` from deleting the VPC/subnets it lives in, not just cost money indefinitely). This run may simply not have gotten far enough into the domain/cert-manager flow to have a real ELB attached yet, or gotten lucky on ordering — that's not something to rely on.

**Impact:** Any real customer-cloud deployment that reaches the point of having a live Ingress (which is the whole point of `ingress-nginx`) and is later torn down via `sol cloud destroy` risks leaving a real, billed AWS load balancer running indefinitely, with nothing in Sol's own tooling ever reporting it — the destroy command would report success.

**Remediation:**
1. In `platform/infra/aws/scripts/teardown-provisioner.sh` (or wherever `sol cloud destroy`'s pre-`terraform destroy` step lives), delete every `LoadBalancer`-type Service in the cluster (or specifically `helm uninstall ingress-nginx -n ingress-nginx`) and wait for the corresponding ELB/NLB to actually disappear before proceeding to `terraform destroy`.
2. Extend `verify_aws_destroy` in `cli/sol/bin/cmd_cloud_tf.ml` to also check for leftover ELBs/NLBs tagged to the cluster (`aws elbv2 describe-load-balancers` / `aws elb describe-load-balancers`, filtered by a cluster-identifying tag), matching the existing EKS/RDS/ECR pattern.
3. Validate against a real cloud teardown — this cannot be verified without provisioning and tearing down a real cluster with an actual Ingress in place; the current investigation only confirmed *this specific run* happened not to leave one behind, not that the code path is safe in general.
