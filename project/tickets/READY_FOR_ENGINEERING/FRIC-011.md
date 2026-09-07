---
id: FRIC-011
type: dogfood-finding
severity: blocker
source: project/dogfood/RUN_2026-09-07_AWS.md (DOGFOOD-011, first real AWS dogfood run)
---

**Depends on:** None.

ECR repository naming (Terraform, keyed on `cluster_name`) and image-reference construction (`sol deploy`, keyed on the workspace/project name) are structurally disconnected — `sol deploy` cannot reference an image at the path Terraform actually provisioned unless a user's cluster name happens to equal their workspace name.

**Description:** `platform/infra/aws/main.tf`'s `aws_ecr_repository.services` names each repository `"${var.cluster_name}/${each.value}"` (`main.tf:140`). But `Sol_cli_deployment_plan.image_ref` (`cli/sol/lib/sol_cli_deployment_plan.ml:266-267`) constructs the image reference `sol deploy` actually pushes to and applies as `"${registry}/${workspace}/${k8s_name}:${tag}"`, where `workspace` is the local checkout's directory basename (`cmd_deploy.ml`'s `workspace_name()`) — entirely independent of `cluster_name`.

Confirmed live during DOGFOOD-011: cluster `sol-smoke-test-0907` hosting workspace `pluto` produced Terraform-provisioned ECR repos at `sol-smoke-test-0907/charge-svc` and `sol-smoke-test-0907/notify-worker`, while `sol deploy` referenced (and `docker push` was expected to target) `pluto/charge-svc` and `pluto/notify-worker`. These never matched. The scaffold-generated CI/CD workflow template (`sol_cli_scaffold_templates.ml:254`, `:410`) already correctly uses the workspace name (`{{name}}`) for its own `docker build`/`docker push` — meaning the *intended* design is clearly workspace-name-based, and `main.tf`'s `ecr_repositories` handling is the actual bug, not `sol deploy`.

**Impact:** For any real deployment where the EKS cluster name differs from the workspace/project directory name — the common case; nobody names their cluster identically to their app's directory — every `sol deploy` against a Terraform-provisioned AWS environment fails with `ImagePullBackOff`/repository-not-found, with no workaround short of manually creating ECR repos with a different naming scheme than what Terraform manages. This breaks the entire "cloud init provisions everything you need" premise DOGFOOD-011 exists to validate, for the one piece (image registry) genuinely load-bearing for every single deploy.

**Remediation:** Change `platform/infra/aws/main.tf`'s ECR repo naming to key on the workspace name, not `cluster_name`. Concretely: add a `workspace_name` Terraform variable (populated by `sol cloud apply`/`sol deploy` from the same `workspace_name()` the CLI already computes, matching how `cluster_name` and other target-file-derived values are already passed as `--var`), and change `aws_ecr_repository.services`'s `name` to `"${var.workspace_name}/${each.value}"`. This is a pre-alpha, no-backwards-compat codebase (per `~/Code/CLAUDE.md`) — no compat shim needed, just fix the naming and update call sites. Verify with a real `terraform plan` showing the corrected repo names, and ideally a real (or at least local k3d-parity) `sol cloud apply` + `sol deploy` round-trip confirming the reference now matches.

**Not yet determined:** whether `ecr_repositories`' values (currently bare service names like `"charge-svc"`) should stay bare and let `main.tf` prepend `workspace_name`, or whether callers should pass full `"${workspace}/${service}"` paths and `main.tf` should use `each.value` verbatim — either works; pick whichever keeps `cmd_cloud_tf.ml`'s existing `--var ecr_repositories=[...]` construction (if any exists there) simplest. Check whether `sol cloud apply`/`sol deploy` already auto-derive `ecr_repositories` from discovered services (similar to how `create_rds` is auto-derived per `smoke-test.tfvars`'s own comment) — if not, that's arguably part of this same fix, since a real user shouldn't have to manually enumerate every service's repo name as a `--var` either.
