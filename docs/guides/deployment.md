# Deploying to your own cloud

From "it runs locally" to "it is running in my AWS account": choosing a target, provisioning the
substrate, deploying the application directly or through GitOps, and wiring CI.

This is the narrative path. The operator-level detail is
[production-bootstrap.md](../deployment/production-bootstrap.md) (the durable installation, identities and
recovery), [substrate.md](../reference/substrate.md) (what Sol generates and what you bring),
[escape-hatches.md](../deployment/escape-hatches.md) (the `sol.toml` overrides), and
[compatibility.md](../deployment/compatibility.md) (what a profile admits today). This page links them instead
of repeating them.

## 1. Choose a target

A target is `<env>/<provider>/<region>` — `prod/aws/us-east-1`. It is the only thing a
deploying command needs, and it is always the positional:

```bash
sol deploy prod/aws/us-east-1       # target-addressed: the target is the positional
sol status payments --target prod/aws/us-east-1
```

Two layers, doing two different jobs (`DEC-016`):

- The **environment** is *policy*: the profile it selects, its base domain, resource sizes,
  service scaling, the alert-delivery contract. It is declared once in
  `sol/environments.yml` — pluto declares `prod`, `pilot`, `dev` and `customer_cloud`.
- The **target** is *where*: the provider and region, and the cluster name.

```yaml
prod:
  base_domain: pluto.example.com
  letsencrypt_email: ops@pluto.example.com
  services:
    charge_svc:
      scale:
        min: 1
        max: 2
  targets:
    aws/us-east-1:
      cluster_name: pluto-prod
```

`sol deploy prod/aws/us-east-1` resolves `sol.yml` → `prod` → `aws/us-east-1`, a lower layer
overriding a higher one. There is no `--env` and no ambient current target: the destination comes
from the target, not from the shell (`DEC-020`). Account-specific values you would rather not
commit go in `sol/environments.local.yml`, which is gitignored and may only add keys
`environments.yml` leaves unset.

An environment's **name never selects a profile**. `prod` above deliberately has none, and
`pilot` selects the production profile explicitly with `profile: production-single-region` — so a
"production" deployment is a decision you write down, not a name you type.

Inspect what a target resolves to before changing anything:

```bash
sol target show prod/aws/us-east-1
sol plan prod/aws/us-east-1 \
  --image-ref charge_svc=registry.example/charge@sha256:<64-hex-digest>
```

`sol plan` resolves the target once, then previews its target-wide infrastructure and
authorization plans plus the desired workload images. On an existing deployment, omitted
image refs inherit immutable images from the current release record; supplied refs override
those images. A first deployment needs one immutable `--image-ref` for every non-omitted
workload. If the current cluster or release record cannot be read, supply the complete map
explicitly. If the durable installation is positively absent, Sol shows its bootstrap plan
using temporary local state. Partial or unknown installation state is deferred. Planning
never applies changes.

`sol plan` also reports the **live workload delta**, classified only by recorded UID
evidence: each declared workload is `create`, `owned, unchanged`, `live, not owned`, or
`recorded, gone`, and live workspace objects the plan does not declare are listed as
surplus (`removable` only while the live UID matches the UID captured at apply, otherwise
`retained`). When the cluster, credentials, or a kind cannot be observed, Sol says so
explicitly and infers nothing about those objects: absence of observation is not
observation of absence. Kubernetes live-object changes are never inferred from labels or
declarations; removal requires positive ownership evidence (see
[resource ownership](../architecture/ownership.md)).

## 2. The installation comes first, once per account

The durable layer — the Terraform state backend and locking, the provisioning/cluster-access/
deploy/operator identities, and the delegated DNS zone when Sol owns one — is per **account**, not
per environment. It outlives every environment, which is why `sol cloud destroy` removes an
environment and never the installation.

**Guided first-run.** `sol deploy` observes the durable installation and offers to establish it
when needed. After that, every cloud-backed deploy reconciles the target's cluster and platform
roots before continuing to authorization and workloads. `--dry-run` and `--emit-to` remain
read-only. The durable installation stays separate: `sol uninstall` removes it under its own
confirmation contract. Where a provider declares no deploy identity — today, GCP — the run stops
after provisioning and names the kubeconfig command and `kube_context` the operator must add. The
identity contracts and external setup steps are in
[production-bootstrap.md](../deployment/production-bootstrap.md).

## 3. Provision the substrate

The substrate is the cluster and platform components Sol runs on it. `sol plan` is the read-only
review step, and `sol deploy` reconciles the whole cloud-backed target:

```bash
sol plan prod/aws/us-east-1                     # full target preview; nothing is applied
sol deploy prod/aws/us-east-1                   # reconcile infrastructure and workloads
```

- `sol plan` previews the existing target Terraform roots, authorization, and workload changes.
  Cluster and CRD prerequisites are reported as explicit deferrals when they are not yet present.
- `sol deploy` applies fresh Terraform plans for the existing roots, verifies the platform, then
  reconciles configured authorization and workloads. Uncertain state, unsafe grant revocation, and
  unknown Kubernetes ownership fail closed.
- Target teardown still uses `sol cloud destroy` until the destroy migration is complete. It does
  not remove the durable installation; use `sol uninstall` for that separate scope.
- Add workspace Terraform under `sol/terraform/<provider>/{cluster,platform}`. It joins the
  matching existing root and state; see the
  [substrate reference](../reference/substrate.md#workspace-owned-terraform) for the stable
  `local.sol_target` interface.

What the substrate contains, and which parts Sol generates versus which you bring, is
[substrate.md](../reference/substrate.md). The `sol.toml` overrides that change what Sol renders
are [escape-hatches.md](../deployment/escape-hatches.md).

**Profiles admit less than Sol can run.** A target that declares a profile runs that profile's
preflight, and the preflight refuses until the target establishes every guarantee the profile
requires, naming each unmet guarantee and who must act. Today the profile admits OCaml
applications on AWS: TypeScript is staged (`DEC-026` §2, the standing goal **FEAT-102**), and GCP
is not a qualified provider for it. The current verdicts, with their evidence, are in
[compatibility.md](../deployment/compatibility.md).

## 4. Deploy the application

Images must already exist in a registry: Sol deploys images, it does not build them in the
deploying command (a `sol build` is planned, not shipped). Choose how the manifests reach the
cluster.

**Direct mode** — the CLI renders and applies:

```bash
sol deploy prod/aws/us-east-1 --registry 123456789.dkr.ecr.us-east-1.amazonaws.com --image-tag "$SHA"
```

**GitOps mode** — the CLI renders and you commit the result, and a controller applies it:

```bash
sol deploy prod/aws/us-east-1 --emit-to manifests/ --image-tag "$SHA"
```

**Which to choose.** Direct mode is the shorter path: one command, and the cluster credentials
live wherever the command runs. GitOps buys you a reviewable diff of what is about to change and a
controller that reconciles drift, at the cost of a pipeline that commits. Both render the same
manifests from the same inputs — the difference is who applies them, not what they say — so
switching later is a change of mechanism, not of contract.

Both modes take the same inputs, and both are honest about what they would do:

- `--dry-run` runs everything except the change.
- `--emit-plan-to plan.json` captures the typed deployment intent without rendering, which is what
  a review gate should consume.
- `sol deploy` reconciles the whole target; there is no `--scope`. The desired workload set
  must be singular so a later removal can be authorized against it, so a narrow update is a
  separate, explicitly non-deleting operation (`sol rollback`) rather than a partial deploy.
- `--keep-releases N`, `--refresh-interval`, `--secret-*`, `--key-prefix`, `--loki-push-url` and
  `--confirm-group-change` cover release retention, rollout refresh, secret backends and
  telemetry destinations. `--confirm-group-change` is only for a group that is really going
  away; the check that asks for it reads the recorded set while the deploy holds the workspace
  lease, so it decides on the boundary as it is at apply time rather than as it was when the
  command started.

Never rebuild the plan/render/execute logic in your own CI: all deployment decisions (image tags,
namespaces, discovery, secrets) belong to `sol deploy`, and CI's job is to supply the inputs
(`--registry`, `--image-tag`).

Deployed releases are records, not folklore:

```bash
sol releases --target prod/aws/us-east-1     # what is deployed, by content-addressed id
sol rollback --target prod/aws/us-east-1     # restore a recorded boundary
sol deployments --target prod/aws/us-east-1  # the deployment events for this workspace
```

`sol rollback` refuses when a migration since that release is contracting, because restoring
workloads cannot un-apply that.

## 5. CI

Generate the supported workflow into an existing workspace:

```bash
sol ci init github
```

It writes `.github/workflows/sol-ci.yml` (also scaffolded by `sol new workspace`) and prints the
repository variables and provider-side trust it expects. It never overwrites a workflow you have
edited; pass `--force` when you mean to replace one. The generated workflow is checked in at
[`examples/pluto/.github/workflows/sol-ci.yml`](../../examples/pluto/.github/workflows/sol-ci.yml).

The workflow authenticates with **GitHub OIDC** — no long-lived cloud credentials are stored in the
repository. It uses two identities, deliberately separate (`DEC-062` rule 1): the **deploy** identity
runs the deploy, and the **reconciler** identity runs workload authorization, so the identity that
deploys cannot grant cloud authority. The exact subjects, jobs and variables are in
[`deployment/ci.md`](../deployment/ci.md). Configure the provider side once:

- **AWS**: an IAM OIDC provider for `token.actions.githubusercontent.com`, then a deploy role scoped
  to the `production` environment (`SOL_DEPLOY_ROLE_ARN`, the target's `deploy_role_arn`) and a
  reconciler role scoped to the `sol-authorization` environment (`SOL_AUTHORIZATION_ROLE_ARN`, the
  target's `reconciler_role_arn`).
- **GCP**: a Workload Identity Federation provider bound to this repository, plus the deploy service
  account (`SOL_WORKLOAD_IDENTITY_PROVIDER`, `SOL_DEPLOY_SERVICE_ACCOUNT`) and the reconciler
  service account (`SOL_AUTHORIZATION_SERVICE_ACCOUNT`).

Protect the `sol-authorization` environment with required reviewers: the `authorize` job runs under
it (`sol grants plan`, then `sol grants apply`), so adopting, dropping or widening a workload cloud
grant is a reviewed action separate from the deploy. The `deploy` job depends on `authorize`, so a
declared grant is established before the deploy that consumes it — and `sol deploy` still fails
closed if it is not effective.

`SOL_TARGET` is a repository variable and is passed to `sol deploy` verbatim; the workflow never
infers a destination from the branch or the event (DEC-016). Workload secret values are never held
by CI (FEAT-053): seed them with `sol secret set --target <env>/<provider>/<region> <KEY>`, and the
deploy fails closed naming any key that is missing.

The deploy step is the same lifecycle as local execution — `sol deploy <target>` then
`sol migrate <target>` — so nothing about the plan, the render or the apply exists in the workflow.
GitOps mode uses the same workflow with `--emit-to` in place of the direct deploy, and the
`platform/cloud/delivery/argocd/application.yaml` `Application` reconciles what it writes; Sol
ships one CI workflow, not a separate copy per mode.

## 6. What you bring, and what Sol brings

Sol generates the cluster substrate, the platform components and the manifests; you bring the
cloud account, the images, the domain and the decisions above. That split, with the exact list, is
[substrate.md](../reference/substrate.md) — read it before deciding how much of the stack you want
to manage yourself, and [escape-hatches.md](../deployment/escape-hatches.md) for the levels at which you can take
part of it over.

## 7. Where to go next

- Day two — logs, metrics, rollback, destroy — is the operations guide (DOCS-029), and the index
  in [`docs/README.md`](../README.md) says what is published today.
- [The runtime contract](../reference/runtime.md) is what a deployed unit may rely on.
- [Building an application](application-authoring.md) is the other half: what runs once it is
  deployed.
- [`docs/reference/cli.md`](../reference/cli.md) is every command and flag.
