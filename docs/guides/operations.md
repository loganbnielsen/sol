# Operating a deployed environment

The day-two command set: see what is running, read logs, roll back, diagnose, open the
right UI, and tear down — in Sol terms, without dropping into `kubectl` or a provider
console for the ordinary path.

This page is the task-oriented map. The contract behind it lives in
[`DEVELOPER_EXPERIENCE.md`](../DEVELOPER_EXPERIENCE.md) §7 and §10, the exact flag
spelling in [`reference/cli.md`](../reference/cli.md), the deployment path in
[`deployment.md`](deployment.md), and the recovery procedures in
[`../deployment/`](../deployment/). This page links them instead of repeating them.

## 1. The day-two command set

| Command | Answers | Addressed by | Scope it accepts |
|---|---|---|---|
| `sol status [SCOPE]` | Is it healthy, and what is it exposing? | scope | workspace (omit), `domain`, `domain/unit`, `resource/<type>/<name>` |
| `sol logs [--scope DOMAIN/UNIT]` | What did one unit just do? | unit scope | exactly one `domain/unit` (or `--release <id>`) |
| `sol rollback [RELEASE_ID]` | Put back a known-good release | release id or `--commit` | whole release; `--scope` only disambiguates `--commit` |
| `sol check [--scope DOMAIN[/UNIT]]` | Is the declaration valid before anything runs? | scope flag | `domain`, `domain/unit` |
| `sol open <view> [SCOPE]` | Open the operational UI for a scope | scope | workspace (omit), `domain`, `domain/unit` |
| `sol cloud destroy <TARGET>` | Remove one environment | target | the target |
| `sol uninstall <TARGET>` | Remove the installation itself | target | the target |

Two scope rules are deliberate and are not inconsistencies:

- `sol status` and `sol open` take the scope as the **positional** (omitting it means the
  workspace index); `sol logs`, `sol check` and `sol rollback` take `--scope`. That is
  `DEC-031`: the primary axis is the positional, and it differs per command.
- **`sol logs` is unit-only.** A workspace- or domain-wide Loki query is a different
  feature with its own cost and pagination shape, so `sol logs --scope payments` is an
  error rather than a wider query. Use `sol open logs payments` for the wider view.

Scopes resolve through the same selector grammar everywhere: `domain` or `domain/unit`,
where the unit is a service, worker or function in the workspace layout
(`app/<domain>/<unit>/`, `sol.toml`).

## 2. Health and status

```bash
sol status                                  # the workspace index
sol status payments                         # one domain
sol status payments/checkout-svc            # one unit
sol status resource/service/payments/checkout-svc
```

`sol status` is the first command to run when something is wrong: it reports the
workloads Sol deployed for the scope and derives health from Kubernetes' own diagnosis
(readiness, restarts, rollout state, recent events) rather than asserting a verdict of
its own. When the scope is unhealthy it names what is wrong — a CrashLooping container, a
rollout that will not complete, an event that explains why — so the next command is a
diagnosis, not a guess.

The `Observability` block reports whether the backend is *reachable from where you are*.
For the local backend that is `http://localhost:3100`; for a deployed backend Sol does not
guess a URL it cannot see, and prints the exact `kubectl port-forward` command to run
instead.

**Target behaviour.** Cloud health, drift, and last-operation fields are **Target**
(`FEAT-090`): today the page tells you what the cluster says, not what the provider says.
The same output is the surface those fields will extend.

## 3. Logs

```bash
sol logs --scope payments/checkout-svc              # follow (default)
sol logs --scope payments/checkout-svc --no-follow  # a snapshot
sol logs --scope payments/checkout-svc --tail 500
sol logs --release r-1a2b3c4d5e6f7890               # one released identity
```

History: `sol logs` is Loki-first. A snapshot (`--no-follow`) queries Loki, which holds
logs from pods that have already been replaced — `kubectl logs` cannot show those — and
falls back to `kubectl logs` when the query fails, so a missing or unreachable Loki degrades
to the direct path instead of failing the command. With a deployed backend and no
`--loki-base-url`, Loki is skipped entirely rather than guessed at; the command says so and
goes straight to `kubectl`.

Before streaming, Sol prints a copyable Grafana Explore URL with the LogQL query it would
run, so the same view is one click away when the terminal is not enough. Use
`sol open logs <scope>` for the wider, queryable view — a live tail is bounded by the
buffer and the connection, while Explore can go back in time and across units
(see [`observability-backends.md`](../deployment/observability-backends.md)).

## 4. Releases and rollback

A deploy records a **release**: the commit, the images by digest, the workload set, and
the migration contract that was in force. `sol rollback` restores one of them:

```bash
sol releases --target prod/aws/us-east-1        # what is recorded
sol rollback r-1a2b3c4d5e6f7890                 # restore that release
sol rollback --commit 4f2a1c9                    # the release that commit deployed
```

`sol rollback` refuses to guess. `--commit` lists the candidate releases and refuses when
more than one matches; `--scope` narrows which of a commit's releases to resolve and never
means "restore part of a release" — a release's workload set is always restored whole. If
a migration since that release **contracts** the schema (drops or narrows something the
code at the rollback target still reads), rollback refuses rather than restoring a release
the database can no longer serve; that is the same gate `sol deploy` applies
([`migration-ordering.md`](../deployment/migration-ordering.md)).

After restoring, Sol verifies the workloads independently rather than trusting the apply,
and moves the current-release pointer. The release record is durable, with enough identity
to reconstruct what a rollback would restore without the machine that deployed it
(`DEC-018`).

## 5. Diagnostics

```bash
sol check                       # the whole workspace
sol check --scope payments      # one domain
sol check --scope payments/checkout-svc
```

`sol check` validates declarations **without Docker or Kubernetes**: the workspace
manifest, every `sol.toml`, the Dockerfile each unit needs, the app/unit layout, and the
declared contracts. It is the command to run before a deploy, in CI, or after a merge that
touched declarations.

Exit status is part of the interface (`DEC-031`'s exit vocabulary): **0** means the
declaration is valid, **2** means it ran and the answer is *no* — a check failed, and the
findings name the unit and what is wrong — and **1** means it could not do the job at all
(not inside a workspace, unreadable file). A name in `--scope` that matches nothing fails
closed and lists what does, rather than quietly checking nothing.

`sol check` today covers declaration validity. Target/scope diagnostics — asking the
cluster and the provider about a deployed environment — are **Target** (`DEVELOPER_EXPERIENCE.md` §7).

## 6. Open the right UI

```bash
sol open dashboard                      # the workspace/services dashboard
sol open metrics payments               # one domain's metrics
sol open logs payments/checkout-svc     # Explore logs for one unit
```

`sol open` resolves the Grafana URL for the selected backend and the scope, and either
opens it in a browser or prints it (`--links`). For a self-hosted durable backend the URL
comes from the target's base domain (`grafana.<base-domain>`); for a local cluster it is
`http://localhost:3000`. It never guesses a URL it cannot resolve: it prints the exact
port-forward to run and exits with the reason.

**Target behaviour.** `sol open traces` and `sol open infra` are **Target**
(`OBS-045`, `INFRA-027`) — traces and an infrastructure view are the two operational
signals with no CLI surface yet.

## 7. Destroy an environment

```bash
sol cloud destroy prod/aws/us-east-1 --apply
```

This removes the environment's network, cluster, database, registry use, platform and
workloads through supported lifecycle operations. It is target-addressed and applies the
same plan-then-apply discipline as `sol cloud apply`; without `--apply` it previews and
changes nothing.

Before anything is destroyed, Sol **releases the workloads this target deployed** (`DEC-059`):
it discovers them in the target's declared namespaces by the ownership labels Sol renders,
removes them by name, and waits for their pods to go. The point is the managed database — a
provider must not be asked to drop durable application state while the workloads that hold
sessions to it are still running.

If Sol cannot establish that those workloads are released, the destroy **stops before it
destroys anything**: it names the namespace, the kind and the operation that failed, destroys
nothing, claims no absence, and exits 1. Resolve the release — bring the workload down, or
repair the deploy identity's authority over the namespace — and re-run. The precondition does
not apply when there is no cluster to release from: a target whose substrate is already absent
is still idempotent, and a cluster that cannot be reached is recorded as a degradation rather
than blocking a teardown that would otherwise be stranded. `--accept-unreleased` destroys
anyway, and the run records that the absence check, not the release, decided the outcome.

Destroy **verifies absence independently** (`DEC-044`, `DEC-040`): after Terraform
converges, Sol re-observes the provider and reports what is absent, what is retained, and
what it could not observe. An unqueryable answer is `UNKNOWN` and fails closed — a command
that exited zero is never the evidence that a resource is gone. A declared destruction-time
guarantee that cannot be prepared (a final-snapshot retainer, for example) blocks the run
rather than proceeding without it.

What it **leaves intact is the installation**: the Terraform state backend and its locking,
the provisioning/cluster-access/deploy/operator identities, and the delegated DNS zone when
Sol owns one (`DEC-057` §3). That is the point of the model — destroying an environment and
redeploying it never means redoing registrar or DNS work. The operator detail, including
what to do when the state backend is present but the cloud root is not, is in
[`production-bootstrap.md`](../deployment/production-bootstrap.md) and `INFRA-082`.

## 8. Uninstall Sol

```bash
sol uninstall prod/aws/us-east-1
```

Removing the **installation** is a separate, explicit operation (`DEC-057` §3). It is never
implied by destroying environments, and destroying all of them does not uninstall Sol.

Without `--confirm`, the command prints what it would remove and what it keeps, and changes
nothing:

- **Removes** the durable resources the installation's Terraform root owns — the state
  facility, and the delegated DNS zone plus its delegation record when the target declares
  Sol owns the zone.
- **Retains** a zone the operator supplied or that is delegated externally, the registrar
  NS records (which live outside every provider API Sol can call), and the four identities,
  which the durable root does not create — the operator creates them from its policy output.

Removing a Sol-created delegated zone has a visible external effect: the NS records at the
registrar become stale, and a recreated zone gets different nameservers. It therefore needs
its **own** confirmation naming the exact domain:

```bash
sol uninstall prod/aws/us-east-1 --confirm --confirm-dns-zone pluto.example.com
```

Afterwards Sol re-observes each removed resource with the installation's own probes and
reports which are absent; anything it cannot observe stays `UNKNOWN` and the command fails
closed rather than reporting it removed. The Terraform state facility is the one structural
exception to the root's lifecycle — a root cannot destroy the backend that stores its own
state — so Sol takes it out of the root's state before the destroy and retires it
explicitly afterwards.

## 9. Recovery pointers

- **Data** — [`application-data-recovery.md`](../deployment/application-data-recovery.md)
  (PostgreSQL backups, PITR, restoring into a clean target).
- **Credentials** — [`credential-rotation.md`](../deployment/credential-rotation.md).
- **Availability** — [`workload-availability.md`](../deployment/workload-availability.md)
  (node loss, drain, slow starts, consumer resumption).
- **Migrations** — [`migration-ordering.md`](../deployment/migration-ordering.md).
- **Observability** — [`observability-backends.md`](../deployment/observability-backends.md).
- **Escape hatches** — [`escape-hatches.md`](../deployment/escape-hatches.md) when the
  supported path genuinely does not fit.

## 10. Where to go next

- The contract this page implements: [`DEVELOPER_EXPERIENCE.md`](../DEVELOPER_EXPERIENCE.md) §7, §10.
- Every flag and exit code: [`reference/cli.md`](../reference/cli.md).
- Deploying in the first place: [`deployment.md`](deployment.md).
- Maintaining the substrate: [`production-bootstrap.md`](../deployment/production-bootstrap.md).
