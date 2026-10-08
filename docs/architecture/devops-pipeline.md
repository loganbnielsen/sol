# Sol Factory Pipeline — Architecture Guide

**Audience:** Contributors adding or modifying deployment behavior in Sol.  
**Scope:** CLI commands, OCaml modules, pipeline phases, state management, and where to add tests.

---

## Overview

Sol is a software factory. The CLI is the control panel; this pipeline is the
factory machinery that turns a workspace directory scan and CLI flags into a
typed deployment plan, Kubernetes/GitOps artifacts, release state, and live
cluster changes.

Plans carry typed intent. `Sol_cli_factory.execute` dispatches to
`Sol_cli_executor.run_plan`, which renders the selected workload artifacts before
executing the chosen mode. Direct deployment is coordinated by
`Sol_cli_deploy_run.apply`, including boundary leasing and release/group recording.

Normal users should experience this as one paved path. Contributors should keep
the internals shaped like a compiler pipeline: raw CLI inputs are validated once,
domain intent becomes typed data, generated artifacts are outputs, and accidental
escape hatches do not become public API.

---

## Pipeline Phases

| Responsibility | Current owner |
|---|---|
| Build typed deployment intent | `Sol_cli_deployment_plan.of_services_result` |
| Render each workload | `Sol_cli_deployment_render.render_spec` |
| Render all workloads, then apply/emit/print | `Sol_cli_factory.execute` → `Sol_cli_executor.run_plan` |
| Shared deploy lifecycle: lease, contract read, gates, apply, release and group recording | `Sol_cli_deploy_run.run_lifecycle` |
| Cloud substrate, migration/effective-access gates and provider apply | `Sol_cli_deploy_run.apply` and `cmd_deploy` |
| Local build, push, port-forward and apply operations | `Sol_cli_up_execution` and `cmd_up` |

The modes are `Dry_run`, `Emit_to dir` and `Apply`. Live secret references are
verified before application; emitted artifacts must use an artifact-safe backend.


---

## Consumer-group bookkeeping ownership

`Sol_cli_deployment_state` stores the last successfully recorded workspace intent
for Kafka consumer groups. It is a removal-warning baseline, not provider evidence
that a group is active or that a workload succeeded.

There are three writers: local `sol up` and direct deploy both run
`Sol_cli_deploy_run.run_lifecycle`, which records the release boundary and then the
group record; rollback (`Sol_cli_rollback.execute`) writes separately. Local up has no
release record, so release persistence cannot replace this shared record without also
changing that local lifecycle. The shared owner writes the release and then the group
record; rollback verifies and moves the release pointer before correcting the group
record. A failed group write therefore reports partial completion, not success.

Plans derive group intent from the workspace service inventory, including units
outside a scoped deployment (`Sol_cli_deployment_plan.derive_consumer_groups`).
Releases describe selected and retained workloads, and rollback reconstructs groups
from Kafka-consuming workers (`Sol_cli_rollback.consumer_groups_of_release`). Those
representations have different inputs: a scoped plan's declaration is not necessarily
the applied boundary, and legacy topic declarations also affect `consumes_kafka`.
Do not equate them without tests for scoped changes and retained workers.

Decision (#1190): the record stays independent. The warning protects the workspace's
**declared** consumer-group intent, while a recorded release describes the **applied and
retained** boundary; a scoped deploy deliberately carries every declared group so the
units it leaves out are not read as removals
(`Sol_cli_deployment_plan.derive_consumer_groups`). Release state therefore cannot
supply the baseline for a scoped deploy. Local `sol up` and direct `sol deploy` record
the plan's declared intent; rollback records the restored release's applied groups
because it restores that boundary. Missing records mean a first deployment; unreadable
records fail the guard unless the operator explicitly passes `--confirm-group-change`.

---

## Deploy lifecycle ownership

Local `sol up` and cloud/direct `sol deploy` share one correctness-sequence owner,
`Sol_cli_deploy_run.run_lifecycle`. Under the boundary lease it reads the prior
contract, presents the plan, runs the target's prerequisite gates, records the plan,
checks consumer-group removal, reads retained state, reconciles and applies, then
records the release boundary and group bookkeeping. The command modules supply only
environment-specific operations — how a plan is presented, which gates a target needs,
how it reconciles and applies, how it reports success, and whether it emits deploy
events — so changing command presentation cannot reorder the sequence. Cloud
`Sol_cli_deploy_run.apply` additionally establishes the destination's substrate and
supplies the migration and effective-access gates. Side-effect-free `--dry-run` and
`--emit-to` run through `Sol_cli_deploy_run.run_offline`, which reads the contract
without a lease because they do not mutate the boundary.

---

## Command map

### `sol local infra up`

**Module:** `cli/bin/cmd_local.ml` → `dev_up`

Provisions a local k3d cluster and installs the local factory substrate via
Helm. Does **not** run the Plan/Render/Execute pipeline. Steps:

1. Check required tools (k3d, helm, kubectl).
2. Create k3d cluster `sol-local` with a local registry on port 5000 (idempotent).
3. Scan the workspace with `Sol_cli_workspace.scan` to discover which infra components
   are needed (Kafka, PostgreSQL, Loki, Prometheus).
4. Install required Helm charts: Redpanda, PostgreSQL (bitnami), Loki, Prometheus.
5. Start background port-forwards via `Sol_cli_port_forward.start` so localhost
   addresses match in-cluster addresses.

**Key modules:** `Sol_cli_workspace`, `Sol_cli_helm`, `Sol_cli_port_forward`, `Sol_cli_state`

**No deployment plan is constructed** — this command manages the local substrate
the rest of the factory targets.

---

### `sol local run`

**Module:** `cli/bin/cmd_local.ml` → `dev_run`

Builds all workspace services with `dune build` and runs each executable directly
on the host (not inside k3d). Injects dev environment variables
(`KAFKA_BROKERS=localhost:9092`, `POSTGRES_URL=...`, etc.) that match the
port-forwards started by `sol local infra up`. Prefixes each service's stdout/stderr with
`[domain/name]`. Stops all children on Ctrl-C (SIGTERM → SIGKILL).

**No Plan/Render/Execute pipeline** — services run as native processes.

---

### `sol up`

**Module:** `cli/bin/cmd_up.ml` → `run`

Full local deploy: builds Docker images, synthesizes manifests, applies to k3d.
This is the self-contained factory path for local smoke tests.

Pipeline:

1. Discover services (`Sol_cli_manifest.discover_services`).
2. Pre-flight: validate `POSTGRES_URL` (injected from in-cluster value if against k3d).
3. Construct env_target with `Sol_cli_env_target.local_defaults`.
4. **Plan:** `Sol_cli_deployment_plan.of_services_result` → `plan`.
5. Consumer group removal guard: compare `Sol_cli_deployment_state.load_deployed_groups`
   with plan's groups; abort if removed groups found (unless `--confirm-group-change`).
6. Copy workspace to a temp Docker context dir (rsync, resolving symlinks).
7. For each service: `Sol_cli_docker.build`, `Sol_cli_docker.push`,
   then `Sol_cli_executor.local ~dry_run`.
8. Wait for rollout (`Sol_cli_kubectl.rollout_status`) for Svc and Worker primitives.
9. Start/refresh port-forward for Svc services.
10. **State:** `Sol_cli_deploy_run.run_lifecycle` records the release boundary and
    `Sol_cli_deployment_state.record_outcome` writes the applied consumer groups.

**Flags:** `--dry-run` (prints YAML, skips build/push/apply), `--tag TAG`,
`--confirm-group-change`

---

### `sol deploy`

**Module:** `cli/bin/cmd_deploy.ml` → `run`

CI/CD deploy: skips image build. Images must already be in the registry. This is
the customer-cloud factory path: Sol owns deployment intent and artifact
synthesis; customer CI or a future `sol build` owns image production.

Pipeline:

1. Discover services.
2. Pre-flight: validate `POSTGRES_URL` (skipped for `--dry-run` and `--emit-to`).
3. Construct env_target with `Sol_cli_env_target.customer_cloud_defaults` (requires
   `--registry`).
4. Guard: `Customer_gitops` mode is incompatible with `Kubernetes_live` secret backend
   (would write plaintext secrets into the GitOps repo).
5. **Plan:** `Sol_cli_deployment_plan.of_services_result` → `plan`.
6. Optionally emit the plan as JSON (`--emit-plan-to`).
7. Select execution mode:
   - `--dry-run` → `Dry_run`
   - `--emit-to DIR` → `Emit_to dir`
   - neither → `Apply`
8. **Execution:** `Sol_cli_factory.execute` uses `Sol_cli_executor.run_plan` to
   render the selected artifacts before applying or emitting them. Direct apply runs
   through `Sol_cli_deploy_run.apply` → `run_lifecycle`; dry-run and emit run through
   `Sol_cli_deploy_run.run_offline`.
9. **State:** `run_lifecycle` records the release boundary and `record_outcome`
   (skipped in GitOps/dry-run modes).

**Flags:**
- `--image-tag TAG` — image tag produced by the CI build job
- `--registry URL` — container registry prefix (e.g. ECR URL)
- `--emit-to DIR` — GitOps mode: write one `<ns>-<name>.yaml` per service to DIR, plus the release artifact (`sol-release-<id>.yaml` and `sol-current-release.yaml`, both derived from the plan's release id)
- `--emit-plan-to FILE` — write plan JSON to FILE (experimental)
- `--dry-run` — print YAML, no cluster contact
- `--secret-backend` — overrides the destination's default: `kubernetes-live` (local and direct deploys — Sol renders no Secret and the workload references the one that already exists), `kubernetes-placeholder` (the GitOps default — a redacted Secret with empty values) or `external-secrets` (with `--emit-to` — an `ExternalSecret` for the External Secrets Operator). The chosen backend is preserved through `--emit-to`; `kubernetes-live` is refused there, because a GitOps artifact is committed to a repository and must never carry live secret values.
- `--secret-store-ref`, `--secret-store-kind`, `--key-prefix`, `--refresh-interval` — External Secrets Operator fields

---

### `sol status`

**Module:** `cli/bin/cmd_status.ml` → `run`

Reads live cluster state. No plan construction.

1. Discover domains from `app/` directory.
2. For each domain, derive the Kubernetes namespace via
   `Sol_cli_deployment_plan.namespace_result`.
3. Call `kubectl get pods -n <ns>` and print output.
4. Query ClusterIP services in the namespace; print a port-forward hint for HTTP
   services (port 80).

**Reads:** live cluster via `Sol_cli_kubectl.get_raw`. **Writes:** nothing.

---

### `sol logs`

**Module:** `cli/bin/cmd_logs.ml`

Derives the Kubernetes namespace and service name from a `domain/name` argument
(or scans `app/` for a bare name). Checks whether the deployment exists, then
emits one or both of:

- A `kubectl logs -n <ns> -l app=<name> --follow` command/stream.
- A Grafana Explore URL built by `Sol_cli_logs.grafana_explore_url` using the
  unit's identity selector `{workspace="<ws>", domain="<domain>",
  service="<k8s-name>"}` — an exact match on the labels Sol writes from
  `Sol_cli_manifest_yaml.taxonomy_labels` (FRIC-029: Sol's Loki streams are keyed
  by `service`/`team`, never `namespace`/`app`). The selector is built once, in
  `Sol_cli_log_selector`, and shared by the Explore link, the printed-log query
  and `--release` narrowing. It used to be a `service=~".*<name>.*"` substring,
  which also returned a same-named unit in another workspace or domain, or a
  longer name such as `fulfillment-worker-ts` (BUG-101).

`--release <id>` (FEAT-069) narrows to one released identity, adding
`release="<id>"` to the selector — or using `{release="<id>"}` alone when no
`--scope` is given, since the id is workspace-unique by construction. The
outcome order is deliberate: a malformed id fails before the cluster is
consulted; a well-formed id with no recorded release fails naming the target and
recent releases; a known release whose query returns nothing is an empty
success, never reported as an unknown release.

**Reads:** live cluster via kubectl. **Writes:** nothing.

---

### `sol deployments`

**Module:** `cli/bin/cmd_deployments.ml`

Lists the deployment events the target's cluster holds for the workspace, newest
first: `DEPLOYMENT / RELEASE / TIME / COMMIT / STATUS / ACTOR`, where the
actor is shown with the source that identity came from (FEAT-110, AUDIT-075). A deployment event
(FEAT-070) is one deploy *attempt* — a minted `d-<YYYYMMDDtHHMMSSz>-<16 hex>` id,
the content-addressed release it tried to put in place, provenance (`created_at`,
git commit, dirty, actor, target), and its outcome (`applied` / `apply_failed`).
It is recorded as an immutable `sol-deployment-<deployment_id>` ConfigMap, so
repeated no-op deploys of the same release appear as separate attempts rather
than being collapsed.

An event is an attempt, not a success (FEAT-071): a failed apply still records an
event and still exits non-zero, but the release record — which says the release
exists — is written only when the apply succeeded. Health is a third fact, read
from the live workload / Argo, never written back into the record.

Two records, one join key: `sol releases` answers "what distinct released states
exist?", `sol deployments` answers "what deploy attempts happened, and which
release did each put in place?". Both readers fail closed on a corrupt matching
record rather than printing a partial list as if it were the whole history. The
deploy marker pushed to Loki carries the same `deployment_id` as a field, and is
only emitted once the record has actually been persisted, so the observability
timeline can never advertise a join to a record that does not exist.

**Reads:** the target cluster via kubectl. **Writes:** nothing.

---

### `sol migrate`

**Module:** `cli/bin/cmd_migrate.ml`

Runs database schema migrations.

Subcommands: `apply` (default), `status`, `rollback`.

**Local mode** (no `TARGET` given) — no Kubernetes manifest pipeline:

1. Resolve `POSTGRES_URL` from the environment, or auto-detect the cluster PostgreSQL
   service and create a temporary port-forward to `localhost:15432`.
2. Open a Caqti/Eio connection pool.
3. `apply`: call `Migration.apply ~table pool ~dir` over SQL files in `db/migrations/`
   (sorted lexicographically, skipping `.down.sql` files). `--dry-run` prints SQL
   without connecting.
4. `status`: call `Migration.status` and print a table of applied/pending files.
5. `rollback` (within migrate): call `Migration.rollback` to undo the last applied file.

**In-cluster mode** (`sol migrate apply <env>/<provider>/<region>`, FRIC-012) —
for any real deployment whose database isn't reachable from outside its own
network by design (e.g. RDS with `publicly_accessible = false`), currently
`apply` only:

1. Resolve a pre-built, **digest-pinned** migration-runner image (SEC-011): an
   installed release reads the digest its bundle records, and a source checkout
   requires `SOL_MIGRATION_RUNNER_IMAGE`. Sol never builds or publishes this
   image — publishing belongs to the publisher identity outside Sol (ADR 0002),
   which for a release is the release workflow that publishes the runner from
   `internal/tooling/release/migration-runner.Dockerfile` and records its digest
   in the bundle. With neither source available the command **fails closed** and
   names both, rather than reaching for registry-write authority the deploy
   identity does not have.
2. Render a ConfigMap from every file in `db/migrations/` and a one-shot
   `batch/v1` Job that mounts it at `/migrations`, uses that image, and runs
   `sol migrate apply --dir /migrations --table <table>` inside the cluster
   (`envFrom` the workspace's `sol-secrets` Secret, so `POSTGRES_URL`
   resolves the same way a deployed service's does) — i.e. the Job re-enters
   local mode from inside the network where the database is actually
   reachable. Runs in the namespace of the first domain `discover_services`
   finds; migrations aren't domain-scoped, and RDS reachability is enforced
   at the VPC/security-group level, not per-namespace.
3. Apply both, poll the Job's `status.succeeded`/`status.failed` fields
   (`backoffLimit: 0`, no silent retry), stream its pod logs, and delete the
   Job/ConfigMap afterward either way.
4. Surface the Job's outcome as `sol migrate`'s own exit status.

`status`/`rollback` do not yet accept a `TARGET` and remain local-mode only.

The migration tracking table defaults to `sol_<workspace>_schema_migrations`,
derived from the workspace directory name. Override with `--table`, which refuses a
name PostgreSQL would truncate. A workspace directory name long enough to push the
derived name past PostgreSQL's 63-byte identifier limit yields a shorter readable
prefix plus a stable hash of the full name, so long-named workspaces sharing one
database still track migrations separately.

---

### `sol rollback` (FEAT-066, DEC-018)

**Module:** `cli/bin/cmd_rollback.ml` → `run`  
**Library:** `cli/lib/deploy/sol_cli_rollback.ml`, `sol_cli_release_store.ml`,
`sol_cli_migration_disposition.ml`

Takes a `RELEASE_ID` positional (`sol rollback <release-id>`, found via
`sol releases`), or `--commit <sha>` (FEAT-073) to resolve that commit's
successful deploy to a release id instead of naming one directly — always
echoed before anything mutates, and refused (candidates listed) rather than
guessed if the commit matches more than one release. `--scope DOMAIN[/UNIT]`
narrows which of a commit's releases `--commit` resolves to when it deployed
more than one (e.g. `payments` and the whole workspace as two separate
releases); it is a *selector* only — a release's recorded workload set is
always restored whole, never partially.

**A boundary is complete, and each workload carries its own provenance
(BUG-077).** A release record does not hold bare specs; it holds
`{ spec; applied_by }` per workload, where `applied_by` is the id of the deploy
that applied that workload. A scoped deploy therefore records a *complete*
workspace boundary: the workloads inside its scope take the new spec and the
new deploy's id, and every workload outside it keeps both the spec and the
provenance it already had, read from the current boundary before anything is
mutated (a scoped deploy refuses, before any mutation, if that boundary cannot
be read — a whole-workspace deploy does not need it, because it supersedes
every workload). Rollback verifies and re-applies each workload under *its own*
`applied_by`, so restoring a boundary that touched one unit neither re-labels
nor prunes the units it never touched, while a full-workspace deploy that drops
a workload still records a boundary without it and rollback still prunes it.
The boundary's id is derived from the workloads the deploy applied together
with the provenance of the ones it inherited — a whole-workspace deploy with
nothing inherited is exactly its content id, as before — so a record's content
is always a function of its id and the immutable ConfigMap is never rewritten
with different content. `--commit` resolution is authoritative
(FEAT-070's deployment-event record), never Loki. Either form restores that
recorded release boundary. Does not use `kubectl rollout undo` — that
mechanism cannot restore config, volumes, or ingress. Restoration comes
entirely from the release record `sol up`/`sol deploy` write on every deploy
(FEAT-067):

1. **Resolve + load + validate** — `Sol_cli_release_store.get` fetches the
   `sol-release-<id>` ConfigMap, decodes it, and checks it both rederives its
   own `release_id` and belongs to the calling workspace. The record also
   carries `data.record_digest`, a free digest of the complete record body:
   a missing or mismatched digest is an unsupported/integrity failure, so the
   non-identity safety fields (`migrations`, `apply_mode`) are as
   tamper-evident as the id. The body declares the `encoding_version`
   (`Sol_cli_release_id.encoding_version`) it was written with, so the three
   reasons the identity check can fail are told apart instead of collapsing
   into one "corrupt" verdict (AUDIT-077): a record written by an older
   encoding says so and is refused as predating a release-identity format
   change; a record that declares no marker at all (written before this CLI
   recorded one) is refused as unverifiable, because a format change and
   damaged content cannot be distinguished; only a record that declares the
   current version and still fails to rederive its id is reported as corrupt.
   All three remain fail-closed — the diagnosis differs, not the refusal.
2. **Refuse controller-owned releases** (`Sol_cli_rollback.check_apply_mode`) —
   the record's `apply_mode` is `direct` or `gitops`. A `gitops` release's
   resources belong to a controller, so a Sol direct apply plus immediate
   readback would not establish a stable transition; rollback refuses before
   touching anything. A controller-mediated rollback path does not exist yet.
3. **Migration boundary check** (`Sol_cli_rollback.check_migration_boundary`,
   DEC-018) — refuses if any migration file that exists now but not at deploy
   time either declares a `Contract` disposition or fails to declare one at
   all. Every migration file must open with a `-- sol:disposition
   expand|contract` header (`Sol_cli_migration_disposition`); there is no
   "assume expand" fallback and no `--force`. This runs before any
   render/apply preparation, so a refusal leaves the cluster untouched.
4. **Reconstruct** — `Sol_cli_rollback.service_specs_of_release` decodes the
   record's workloads back into `service_spec`s using only the record plus
   pure helpers (canonical inverse decoders, `k8s_name_result`,
   `namespace_result`, `service_url`, `call_env_var`) — never the workspace,
   `sol.toml`/`sol.yml`, the environment, or discovery. `called_by` is derived
   from the record's own `calls` rows, not a stored forward-edge env var.
5. **Render + apply** — `Sol_cli_deployment_render.render_spec` per spec
   (`Kubernetes_live` secret backend — secret values, never persisted, are
   read from the process environment same as any direct apply), then
   `Sol_cli_manifest.apply`.
6. **Verify the workload set** (`Sol_cli_rollback.live_workloads` +
   `verify_workloads`) — enumerates every live Sol-owned workload for the
   workspace (Deployment/Rollout/CronJob whose pod template carries the
   `workspace` label) and compares that *set* to the restored release's
   workloads: a wrong `release` label or a missing object still fails the
   rollback outright — neither is fixable by deleting something. An
   **unexpected** object left over from the superseded release is different
   (FEAT-074): see the next step. This runs *before* the pointer moves, so a
   mismatch leaves the pointer unchanged rather than claiming a transition
   that did not happen.
7. **Prune surplus workloads** (`Sol_cli_rollback.prune_workloads`, FEAT-074)
   — only reached once step 6's mismatched/missing modes are clean. Deletes
   exactly the workloads step 6 found unexpected (possibly none) — the
   primary Deployment/Rollout/CronJob object only, not the removed service's
   other rendered objects (ConfigMap/Secret/PVC/Service/Ingress/
   NetworkPolicy/ServiceAccount): deleting a PVC automatically risks real
   data loss, and cleaning up the rest needs its own ownership/ordering
   design this ticket did not attempt. A prune failure leaves the pointer
   unchanged, same as a step-6 refusal.
8. **Pointer move** — `Sol_cli_release_store.move_pointer` writes only the
   mutable `sol-release-current-<workspace>` ConfigMap, and only after the
   live set agrees and any surplus is pruned; the immutable per-release
   ConfigMap already exists and is not re-applied.
9. **Verify the pointer** (`Sol_cli_rollback.verify_pointer`) — reads back
   `data.release_id`, reported independently of the workload report. Never
   re-applies or "fixes" a mismatch. A pointer whose read fails is reported as
   unreadable with the read's cause — an outcome distinct from a pointer that
   was read and names another release — and fails verification just as a
   mismatch does; an unread pointer is never rendered as `<none>`.

Steps 2–9's ordering — refusal before mutation, pruning only once the
mismatched/missing modes are clean, pointer move only once pruning succeeds —
is `Sol_cli_rollback.execute` (FEAT-075), not inline logic in
`cmd_rollback.ml`: the sequence is a tested library function taking steps
5/6/7/8/9's cluster-touching parts (`apply`/`live_workloads`/`prune`/
`move_pointer`/`verify_pointer`) as injectable deps, so a reorder that put a
mutation ahead of a refusal — or the pointer ahead of workload verification
or pruning — fails a test rather than only a future incident.

**`sol up`/`sol deploy` report the same surplus, but never delete it**
(FEAT-074): after a successful whole-workspace apply, both compare the live
Sol-owned workload set against the plan's `services` (reusing
`Sol_cli_rollback.unexpected_workloads`, the same pure diff `verify_workloads`
uses) and print a note listing anything surplus. A `sol up --scope` skips
this — its plan is only part of the workspace, so comparing it against every
live workload would flag out-of-scope services as false surplus (`sol deploy`
has no `--scope`: it always reconciles the whole target). Unlike
rollback, a deploy has no recorded release boundary backing "this is exactly
what should exist", only what it was asked to deploy this run, so it never
prunes automatically; the note points at `sol rollback` for that.

**Mutation boundary (FEAT-072).** Before any step below mutates anything,
rollback acquires the workspace's boundary lease — the mutable
`sol-boundary-lease-<workspace>` ConfigMap (`Sol_cli_boundary_lease`), the same
lease `sol deploy`/`sol up` hold while applying. Acquisition is a `kubectl
create`, so the API server is the arbiter and two processes cannot both believe
they own the boundary. If a live deploy holds it, rollback asks it to abort and
polls for the lease to go quiet; if it cannot establish quiescence within the
wait window it refuses and names the holder rather than racing it. A second
rollback refuses outright. A holder whose heartbeat is older than the TTL is
treat as crashed and may be taken over with a `resourceVersion`
compare-and-swap. The lease is acquired and released by a bracket
(`Sol_cli_boundary_lease.with_boundary_lease`); the body it wraps — the whole
apply path — returns a `result` rather than calling `exit`, so the lease is
released exactly once on every path and the command edge is the only place a
refusal becomes a process exit.

Ownership is not just acquired once: every mutation re-verifies it against the
live lease (`Sol_cli_boundary_lease.ensure_held`, a heartbeat write guarded by a
`resourceVersion` compare-and-swap) — before each workload `apply`, before the
surplus `prune`, and before the pointer move — and `sol deploy`/`sol up` do the
same before recording the release and advancing the pointer. That is also the
renewal: a long rollback or deploy keeps pushing its heartbeat forward as it
works, so a long healthy operation is never taken over mid-flight. Losing
ownership is a **stop**, not a race: the next check fails and the operation
returns an error before its next mutation, leaving the current-release pointer
unchanged, so a new owner finishes the boundary without the old one still
writing into it. An operation already in progress when the takeover happens
therefore completes at most the mutation it was inside and no more — there is no
forced kill.

GitOps-mode rollback (content and pointer travelling in one emitted commit) and
`--commit`/`--scope` release disambiguation are not yet implemented — this
command only accepts an exact, unambiguous release id against a live cluster,
and refuses a release recorded as GitOps-owned.

### Release retention (FEAT-072, DEC-018)

**Module:** `cli/lib/deploy/sol_cli_release_retention.ml`

A successful `sol up`/`sol deploy` bounds the workspace's release history to the
last `--keep-releases N` distinct release records (default 20, DEC-018). The
current pointer target and the release the pointer named before the transition
are never pruned, even when they fall outside the window. Order comes from each
record's cluster-assigned `metadata.creationTimestamp` (the record itself
deliberately carries no timestamp, FEAT-069); duplicate deploys of identical
content collapse to one distinct release. Only the immutable `sol-release-<id>`
ConfigMaps are deleted — the current-release pointer and the deployment-event
history are untouched, since "how many releases are recent" and "what happened"
are different retention questions. Pruning is best-effort/non-fatal: a pruning
failure warns and does not turn a successful deploy into a failure.

**State:** does **not** update `Sol_cli_deployment_state` after rollback. The
consumer group guard on the next `sol up`/`sol deploy` will re-read the cluster
state.

---

## Where release history lives, and reading it without Sol (FEAT-110)

**The durable owner is the target cluster.** Release and rollback metadata is
held as ordinary Kubernetes ConfigMaps in the customer's own namespace, on the
customer's own provider:

| Record | Object | Namespace |
|---|---|---|
| A released state | `sol-release-<release_id>` (immutable) | the first discovered service's domain namespace |
| The rollback target | `sol-release-current-<workspace>` (mutable pointer) | same |
| One deploy attempt | `sol-deployment-<deployment_id>` (immutable) | same |

That is a deliberate choice, not an accident of implementation: it is
provider-native, it keeps Sol from operating a service or a second
infrastructure-state database (ADR 0003), and it means the record survives
stopping the use of Sol entirely. A GitOps `--emit-to DIR` deploy writes the same
release record as `sol-release-<id>.yaml` into the customer's own git
repository, which is a second copy under the same owner. The record's identity is
content-addressed from the workload boundary **and the deployed event contract**
(`Sol_cli_release_id`, encoding `sol-release-v5`), so a record can be re-derived
and checked, not merely believed, and a contract-only change is still a distinct
release a rollback can name.

**The record carries the deployed contract.** Each Sol-owned event's declaration
facts — registry subject identity, topic, partition count, key field and schema
digest — are stored with the record, language-neutrally, so the contract a deploy
actually established is inspectable from the target and restored by a rollback to
a release whose record carries it. A later deploy compares the declaration against
that recorded value and renders the change as `observed → desired` (for example
`payments.Charged  partitions 3 → 6`) instead of only printing the new
declaration. The comparison needs the target, so it belongs to deployment planning
— `sol deploy`, including `--dry-run` and `--emit-to`; `sol plan` stays offline
and keeps reading the declaration. A change that cannot be reconciled in place — a
partition reduction, a record-key change, or a topic rename — fails closed and
names the reason before anything is applied.

Reading that baseline needs the current release pointer and the record it names. If
either cannot be read — permission denied, a malformed record, or a pointer naming a
release that is not there — the deploy refuses and reports the read that failed
instead of treating the target as a first deployment: an unreadable baseline cannot
prove a change is compatible. Nothing has been applied, so fix the read (for example
`kubectl -n <namespace> get configmap sol-release-current-<workspace>`) and deploy
again. Only a genuinely absent pointer is a first deployment.

**Reading it with no Sol binary.** Everything the CLI reads is in those
ConfigMaps, under the `record` key:

```bash
# where they are: the records carry sol.dev/workspace, so no namespace needed
kubectl get configmap -A -l sol.dev/workspace=<workspace> \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,AT:.metadata.creationTimestamp
# the rollback target, then the release it names (records are data.record)
NS=<namespace from above>
kubectl -n "$NS" get configmap sol-release-current-<workspace> -o jsonpath='{.data.release_id}'
kubectl -n "$NS" get configmap "sol-release-<that release_id>" -o jsonpath='{.data.record}' | jq .
# the attempts, and who made each one
kubectl -n "$NS" get configmap -l sol.dev/type=deployment \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.data.record}{"\n"}{end}' | jq -r '.actor_source + " " + .actor'
```

Reading the current pointer and the release it names is enough to identify the
deployed release and the rollback target: the record names each workload's image
digest and the migrations that were applied, so what is running can be described
and operated (rolled forward or back) with `kubectl`/`argo` and the provider's
own tooling alone.

**Provenance is observed, not asserted (AUDIT-075).** A deploy attempt records
the actor *and where that identity came from*: a CI claim from the environment
(`ci:github-actions`, `ci:gitlab`) first, then the workspace repository's
`git config user.email` (`git:local`), then `SOL_ACTOR` (`override:env`), then
nothing at all (`sol deployments` shows `-`). A record never invents an actor,
and showing the source beside the name is what keeps an unverified string from
reading like a signed identity: `SOL_ACTOR` is a convenience, and both it and a
dirty working tree are visible as such.

**Retention is stated, not implied.** Committed release records are pruned to the
last `--keep-releases N` distinct releases (default 20, DEC-018) with the current
pointer and its predecessor always kept. **Deployment events are not pruned**:
`sol-deployment-<id>` ConfigMaps accumulate for the life of the namespace, which
is deliberate — an attempt history that silently loses its oldest entries is
worse than a large one — and the volume question is tracked as AUDIT-076 rather
than answered by quietly deleting history here.

**A record written by an older Sol is diagnosable, not "corrupt" (AUDIT-077).**
The release record carries the `encoding_version` of the format that wrote it. A
reader that finds a different version says the record predates a format change
and cannot be verified against the current rules, and a record with no version
at all says a format change and damaged content cannot be told apart — neither is
reported as corruption, and both fail closed.

---

## Where to add tests

Inline tests live in `cli/test/inline/`; process-level tests remain in `cli/test/`. Each file covers one pipeline layer:

| What you're changing | Test file |
|---|---|
| Plan construction (`of_services_result`, `service_spec` fields, workspace scan) | `test_deployment_plan.ml` |
| Manifest rendering (`render_spec`, YAML shape, secret backends) | `test_manifest_render.ml` |
| Factory dispatch and executor modes | `test_factory.ml`, `test_executor.ml` |
| Full deploy sequence (plan → render → execute ordering) | `test_deployment_phases.ml` |
| Rollback target selection and `execute_rollback` paths | `test_rollback.ml` |
| Deployment state ConfigMap read/write | `test_deployment_state.ml` |
| Executor functions (`local`, `direct`, `gitops`) | `test_executor.ml` |
| Logs URL generation (`Sol_cli_logs`) | `test_logs.ml` |

**Guidance for new contributors:**

- **Adding a new manifest resource** (e.g. a new Kubernetes object type): add a
  rendering test in `test_manifest_render.ml` that checks the YAML string output
  for the expected fields and structure.

- **Adding a new CLI flag that affects the plan** (e.g. a new TOML field): add a
  test in `test_deployment_plan.ml` that verifies `of_services_result` produces
  the expected `service_spec` value.

- **Adding a new execution mode or changing how artifacts are applied**: add a test
  in `test_factory.ml` or `test_deployment_phases.ml` that mocks the plan and
  checks which executor path is taken.

- **Changing rollback behavior** (e.g. supporting a new progressive delivery
  strategy): extend `test_rollback.ml` with a case for the new target type.

- **Any new deployment behavior in `sol up` or `sol deploy`** that is not already
  covered by the above should get an integration-level test in
  `test_deployment_phases.ml`, which exercises the plan → render → execute sequence using a dry-run or stubbed executor to avoid cluster access.

Tests run without a cluster: `eval $(opam env) && dune test cli/test/`.

---

## CI Workflow Contract

There is **one** generated CI workflow, `.github/workflows/sol-ci.yml`
(`platform/shared/templates/workspace/.github/workflows/sol-ci.yml`), written by
`sol new workspace` and by `sol ci init github`. It is a thin wrapper around the same
`sol deploy <target>` lifecycle a human runs locally; no plan, render or apply logic
lives in it.

| Job | Runs when | What it does |
|---|---|---|
| `build-and-test` | every push and pull request | `dune build`, `dune runtest` (the schema gate reads `SCHEMA_REGISTRY_URL`) |
| `build-images` | push to `main` | assumes the deploy identity, builds and pushes each `app/**/Dockerfile` |
| `authorize` | push to `main`, under the `sol-authorization` environment | assumes the target's fenced authorization reconciler and runs `sol grants plan` then `sol grants apply` (`DEC-062`) |
| `deploy` | push to `main`, after `authorize`, under the `production` environment | assumes the deploy identity, runs `sol deploy <target>` then `sol migrate <target>` |

Authentication is GitHub OIDC (`id-token: write`): no long-lived cloud credential and no
`KUBECONFIG` is stored. The deploy identity holds no IAM-mutating permission, so it can
observe effective workload access but never grant it. `SOL_TARGET` is a repository
variable passed verbatim, and the workflow never infers a destination (`DEC-016`). The
identity, subject, variable and environment setup is
[`deployment/ci.md`](../deployment/ci.md).

GitOps mode uses the same workflow with `sol deploy --emit-to` in place of the direct
deploy; the Argo CD `Application` in `platform/cloud/delivery/argocd/` reconciles what it
writes.

**Adding new CI behavior:** Do not add deployment logic to the CI workflow template.
Add it to `sol_cli_deployment_plan.ml` (plan phase) or `sol_cli_executor.ml`
(execute phase), and the CI template will pick it up automatically through
`sol deploy`.

---

## Generated Kubernetes Artifact Invariants

Every resource emitted by `sol up`, `sol deploy`, and `sol local infra up` must satisfy
these invariants. The security context invariants are enforced in
`cli/test/test_manifest_render.ml` via the `assert_k8s_invariants` helper
and the `artifact_invariants` test suite.

| Invariant | Kubernetes field | Status | Notes |
|-----------|-----------------|--------|-------|
| Non-root execution | `spec.securityContext.runAsNonRoot: true` | Enforced | Pod-level; all primitives |
| No privilege escalation | `containers[].securityContext.allowPrivilegeEscalation: false` | Enforced | Container-level; all primitives |
| Read-only root filesystem | `containers[].securityContext.readOnlyRootFilesystem: true` | Enforced | Container-level; all primitives |
| GitOps secret redaction | `Secret.stringData` values are empty strings | Enforced | `Kubernetes_placeholder` mode only |
| Taxonomy labels | `metadata.labels["workspace"\|"domain"\|"service"\|"primitive"\|"release"]` | Enforced | Pod-template labels, unprefixed (not `sol.dev/*` — see `docs/architecture/observability-design.md`); shipped in OBS-008 |
| `env` taxonomy label | `metadata.labels["env"]` | Done | Emitted by `sol deploy <env>/<provider>/<region>` (FEAT-026); `sol up` stays local-only and omits it — see `observability-design.md`'s Identity section |

### What is covered by `assert_k8s_invariants`

The `assert_k8s_invariants label yaml` helper in `test_manifest_render.ml` checks
the three enforced security context invariants on any rendered workload YAML string.
It is applied to: `Svc` (Deployment), `Worker` (Deployment), `Fn` (CronJob),
canary `Rollout`, and blue-green `Rollout`.

The `test_gitops_secret_redacted` test case in the `artifact_invariants` suite
verifies that `Kubernetes_placeholder` mode strips all user-supplied secret values
before the YAML is written to disk.

### When adding a new resource type

1. Add the security context blocks (`runAsNonRoot`, `allowPrivilegeEscalation`,
   `readOnlyRootFilesystem`) to the new YAML template in
   `cli/lib/workspace/sol_cli_manifest_yaml.ml`.
2. Add a corresponding test case to the `artifact_invariants` suite in
   `cli/test/test_manifest_render.ml` that calls `assert_k8s_invariants` on
   the rendered output.
3. Update this table if the new resource changes the invariant surface.
