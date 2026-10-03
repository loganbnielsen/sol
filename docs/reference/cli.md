# `sol` command reference

Every command the `sol` binary registers: its positional argument, the flags it takes, what
a non-zero exit means, and the scopes it accepts.

The tables are **generated from the binary's own help** (`sol <command> --help=plain`) by
`internal/tooling/scripts/render-cli-reference.py`, and
`internal/ci/check_cli_reference.py` fails CI when the page and the binary disagree — a new
command cannot be added silently, and the page cannot document a command or a flag that does
not exist. To regenerate after a CLI change:

```bash
python3 internal/tooling/scripts/render-cli-reference.py
```

The narrative of what each command does in a deployment belongs to
[devops-pipeline.md](../architecture/devops-pipeline.md); this page is the exact spelling.

## How a command is addressed (DEC-031, DEC-032)

A command has three possible axes — **target** (where), **scope** (what) and **view** (which
operational concern) — and exactly one of them is *primary* for that command. The primary
axis is the **positional** argument; the other axes are flags. That is why these are both
correct and are not inconsistent:

```bash
sol deploy dev/aws/us-east-1                  # target-addressed: the target is the positional
sol status payments/checkout-svc              # scope-addressed: the scope is the positional
sol open logs payments --target dev/aws/us-east-1
sol up                                        # local: no target exists to resolve
```

- A **target** is always `<env>/<provider>/<region>`, for example `dev/aws/us-east-1`. The
  environment is a property of the target: there is no `--env` and no ambient current target
  (`DEC-016`).
- A **scope** is `domain` or `domain/unit` (for example `payments` or
  `payments/checkout-svc`).

Accepted scopes are deliberately **not** uniform, and widening one is a feature rather than
consistency:

- `sol status` and `sol open` take `workspace`, `domain`, `domain/unit` and
  `resource/<type>/<name>`; omitting the scope means the workspace index.
- The `--scope` commands resolve `domain` and `domain/unit` through the same selector
  grammar.
- `sol logs` is **unit-only** on purpose: a workspace- or domain-wide Loki query is a
  different feature with its own cost and pagination shape, so `sol logs --scope payments` is
  an error rather than a wider query.
- `sol up` and `sol deploy` are different commands for a reason: `sol up` builds and deploys
  to Sol's own local cluster and has no target; `sol deploy` ships pre-built images to a
  target and takes the target as its positional, which `sol up` cannot.

## Exit behaviour

- **0** — the command did what it says.
- **1** — it refused, or it failed. This is the default for every refusal and failure, and
  the code `sol cloud` uses for a target that did not reach its postcondition. The reason is
  on stderr, and a command that refuses before the billable boundary has changed nothing.
- **2** — a *negative answer from a command that ran*: `sol check` when a check fails, and
  `sol alert test` when the target does not satisfy the alert-delivery contract. Exit 1 means
  "could not do it"; exit 2 means "did it, and the answer is no".

No command uses any other code. A command whose own help carries an `EXIT STATUS` section is
marked `documented` in the tables below, and `sol <command> --help` is the authority for it.
Machine-readable output exists where the tables' flags say so (`--json`, `--emit-plan-to`,
`--emit-to`); plan output is the same shape `sol plan` prints.

## Commands that are not registered yet

The reference covers what the binary registers, so the documented-but-planned operations do
not appear here, and each names the ticket that will add it:

- `sol ci init github` — FEAT-109.

Inline first-run onboarding (FEAT-106) adds no command of its own: `sol deploy`
observes the target's durable installation, guides it in place, then reconciles
the target's environment and reaches the cluster as the target's deploy identity
(DEC-058) — so the whole first run is documented with that command rather than
listed here.

## Target-addressed commands

The target is the positional; `--scope` narrows to a domain or unit.

<!-- BEGIN GENERATED: target -->
| command | positional | flags | exit | purpose |
|---|---|---|---|---|
| `sol alert test` | — | `--alertmanager-url=URL`, `--dry-run`, `--target=ENV/PROVIDER/REGION` | documented | Send a synthetic alert through the target's |
| `sol cloud apply` | TARGET | `--accept-unresolved`, `--confirm-ecr-removal`, `--var=KEY=VALUE`, `--var-file=PATH` | documented | Apply cloud infrastructure changes for a target. |
| `sol cloud bootstrap` | TARGET | `--apply`, `--await-delegation=SECONDS` | documented | Report whether a target's durable installation |
| `sol cloud destroy` | TARGET | `--accept-unreleased`, `--apply`, `--plan`, `--var=KEY=VALUE`, `--var-file=PATH` | documented | Destroy cloud infrastructure via Terraform. |
| `sol cloud plan` | TARGET | `--var=KEY=VALUE`, `--var-file=PATH` | documented | Preview cloud infrastructure changes for a target. |
| `sol cloud reconcile` | TARGET | `--dry-run`, `--explain`, `--var=KEY=VALUE`, `--var-file=PATH` | documented | Compare Terraform ownership with independently |
| `sol deploy` | TARGET | `--await-delegation=SECONDS`, `--confirm-group-change`, `--dry-run`, `--emit-plan-to=FILE`, `--emit-to=DIR`, `--image-ref=[SERVICE=]REPO@sha256:DIGEST`, `--image-tag=TAG`, `--keep-releases=N`, `--key-prefix=PREFIX`, `--loki-push-url=URL`, `--refresh-interval=INTERVAL`, `--registry=URL`, `--scope=DOMAIN[/UNIT]`, `--secret-backend=BACKEND`, `--secret-store-kind=KIND`, `--secret-store-ref=NAME` | documented | Deploy pre-built images to a cluster (CI/CD integration). |
| `sol deployments` | — | `--target=ENV/PROVIDER/REGION` | documented | List the deployment events the target's cluster |
| `sol grants apply` | TARGET | `--var=KEY=VALUE`, `--var-file=PATH` | documented | Reconcile the target-wide workload authorization: |
| `sol grants plan` | TARGET | `--var=KEY=VALUE`, `--var-file=PATH` | documented | Plan the target-wide workload authorization |
| `sol logs` | — | `--base-domain=DOMAIN`, `-f`, `--grafana-base-url=URL`, `--loki-base-url=URL`, `--loki-password=PASSWORD`, `--loki-username=USERNAME`, `--no-follow`, `--observability-backend=BACKEND`, `--release=RELEASE_ID`, `--scope=DOMAIN/UNIT`, `--tail=N`, `--target=ENV/PROVIDER/REGION` | documented | Stream logs from a deployed service. Wraps 'kubectl logs' |
| `sol migrate apply` | TARGET | `--dir=DIR`, `--dry-run`, `--registry=URL`, `--table=TABLE` | documented | Apply all pending migrations (default subcommand) |
| `sol plan` | TARGET | — | documented | Print the merged Sol app/resource/service plan for a |
| `sol releases` | — | `--target=ENV/PROVIDER/REGION` | documented | List the release records the target's cluster holds for |
| `sol secret list` | — | `--domain=DOMAIN`, `--target=ENV/PROVIDER/REGION` | documented | List secret keys without values |
| `sol target show` | — | `--check`, `--json`, `--target=ENV/PROVIDER/REGION`, `-v` | documented | Show a deployment target |
| `sol uninstall` | TARGET | `--confirm`, `--confirm-dns-zone=DOMAIN`, `--var=KEY=VALUE`, `--var-file=PATH` | documented | Remove a Sol installation: its Sol-owned durable |
<!-- END GENERATED: target -->

## Scope-addressed commands

The scope is the positional (omitted means the workspace); `--target` selects the target.

<!-- BEGIN GENERATED: scope -->
| command | positional | flags | exit | purpose |
|---|---|---|---|---|
| `sol check` | — | `--scope=DOMAIN[/UNIT]` | documented | Validate Sol workload declarations without Docker or |
| `sol open dashboard` | SCOPE | `--base-domain=DOMAIN`, `--grafana-base-url=URL`, `--links`, `--observability-backend=BACKEND`, `--target=ENV/PROVIDER/REGION` | documented | Open (or print) the Grafana workspace/service |
| `sol open infra` | SCOPE | `--base-domain=DOMAIN`, `--grafana-base-url=URL`, `--links`, `--observability-backend=BACKEND`, `--target=ENV/PROVIDER/REGION` | documented | Open (or print) the target-scoped infrastructure view |
| `sol open logs` | SCOPE | `--base-domain=DOMAIN`, `--grafana-base-url=URL`, `--links`, `--observability-backend=BACKEND`, `--target=ENV/PROVIDER/REGION` | documented | Open (or print) the Grafana Explore logs view. |
| `sol open metrics` | SCOPE | `--base-domain=DOMAIN`, `--grafana-base-url=URL`, `--links`, `--observability-backend=BACKEND`, `--target=ENV/PROVIDER/REGION` | documented | Open (or print) the Grafana metrics dashboard. |
| `sol open traces` | SCOPE | `--base-domain=DOMAIN`, `--grafana-base-url=URL`, `--links`, `--observability-backend=BACKEND`, `--target=ENV/PROVIDER/REGION` | documented | Open (or print) the Grafana Explore traces view, |
| `sol status` | SCOPE | `--base-domain=DOMAIN`, `--loki-base-url=URL`, `--observability-backend=BACKEND`, `--prometheus-base-url=URL`, `--target=ENV/PROVIDER/REGION` | documented | Show workspace/domain/service health and observability |
| `sol up` | — | `--confirm-group-change`, `--dry-run`, `--keep-releases=N`, `--scope=DOMAIN[/UNIT]`, `--tag=TAG` | documented | Build images, synthesize k8s manifests, and deploy to the |
<!-- END GENERATED: scope -->

## Workspace commands

No positional: the command acts on the workspace, and a target or scope is a narrowing flag.

<!-- BEGIN GENERATED: workspace -->
| command | positional | flags | exit | purpose |
|---|---|---|---|---|
| `sol assets` | — | — | documented | Show where this sol's own assets come from (a source |
| `sol ci init` | PROVIDER | `--force` | documented | Write the supported CI workflow into the current |
| `sol fn run` | DOMAIN/NAME | `--target=ENV/PROVIDER/REGION` | documented | Manually invoke a deployed -fn: creates one Kubernetes |
| `sol migrate rollback` | — | `--dir=DIR`, `--table=TABLE` | documented | Roll back the last applied migration |
| `sol migrate status` | — | `--dir=DIR`, `--json`, `--table=TABLE` | documented | Show per-file applied/pending status |
| `sol new event` | TEAM/NAME | — | documented | Add a typed Kafka event contract to the current |
| `sol new fn` | DOMAIN/NAME | `--language=LANGUAGE` | documented | Add a scheduled function to the current workspace |
| `sol new svc` | DOMAIN/NAME | `--language=LANGUAGE` | documented | Add an HTTP service to the current workspace |
| `sol new worker` | DOMAIN/NAME | `--language=LANGUAGE` | documented | Add a Kafka consumer worker to the current workspace |
| `sol new workspace` | NAME | — | documented | Scaffold a new Sol workspace with a working |
| `sol rollback` | RELEASE_ID | `--commit=SHA`, `--scope=DOMAIN[/UNIT]`, `--target=ENV/PROVIDER/REGION` | documented | Restore a recorded release boundary. Refuses on a |
| `sol secret delete` | KEY | `--domain=DOMAIN`, `--target=ENV/PROVIDER/REGION` | documented | Delete a secret key |
| `sol secret set` | KEY | `--domain=DOMAIN`, `--target=ENV/PROVIDER/REGION`, `--value=VALUE` | documented | Create or update a secret key |
<!-- END GENERATED: workspace -->

## Local commands

`sol local …` drives Sol's own local k3s cluster. There is no target and no cloud account.

<!-- BEGIN GENERATED: local -->
| command | positional | flags | exit | purpose |
|---|---|---|---|---|
| `sol local deployments` | — | — | documented | List the deployment events Sol's local cluster |
| `sol local fn run` | DOMAIN/NAME | — | documented | Manually invoke a deployed -fn on the local |
| `sol local infra down` | — | `--cluster` | documented | Stop port-forwards (and optionally delete the |
| `sol local infra status` | — | — | documented | Show infra pod health and registered |
| `sol local infra up` | — | — | documented | Provision local k3d cluster and deploy all |
| `sol local logs` | — | `--base-domain=DOMAIN`, `-f`, `--grafana-base-url=URL`, `--loki-base-url=URL`, `--loki-password=PASSWORD`, `--loki-username=USERNAME`, `--no-follow`, `--observability-backend=BACKEND`, `--release=RELEASE_ID`, `--scope=DOMAIN/UNIT`, `--tail=N` | documented | Stream logs from a workload running on the local |
| `sol local migrate` | — | `--dir=DIR`, `--dry-run`, `--registry=URL`, `--table=TABLE` | documented | Apply migrations against the local cluster's |
| `sol local releases` | — | — | documented | List the release records Sol's local cluster |
| `sol local rollback` | RELEASE_ID | `--commit=SHA`, `--scope=DOMAIN[/UNIT]` | documented | Restore a recorded release boundary on the local |
| `sol local run` | — | `-C`, `--scope=DOMAIN[/UNIT]` | documented | Start all workspace services locally using dune exec |
| `sol local secret delete` | KEY | `--domain=DOMAIN` | documented | Delete a secret key |
| `sol local secret list` | — | `--domain=DOMAIN` | documented | List secret keys without values |
| `sol local secret set` | KEY | `--domain=DOMAIN`, `--value=VALUE` | documented | Create or update a secret key |
| `sol local status` | SCOPE | `--base-domain=DOMAIN`, `--loki-base-url=URL`, `--observability-backend=BACKEND`, `--prometheus-base-url=URL` | documented | Show local workload health and observability status |
<!-- END GENERATED: local -->

## Sources of truth

- The registration itself: `cli/bin/` — `main.ml` for the groups, and each `cmd_*.ml` for its
  command and flags. The guard reads the built binary, so the reference cannot drift from it.
- The axis rule: `DEC-031` and `DEC-032`.
- The scope grammar and its deliberate exceptions: `AGENTS.md` § *Core design principles*.
