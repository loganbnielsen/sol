# Sol adversarial production-readiness review — 2026-09-16

Reviewer stance: principal platform engineer who would be on call for
workloads deployed through this platform. Methodology: read the actual
implementation (not just docs/changelogs), search `pipeline/tickets/` for
prior coverage before flagging anything, and test claims experimentally
where practical (a live k3d cluster was used for concurrency tests; no
real AWS/GCP infrastructure was touched).

## Executive assessment

Sol's core compiler-pipeline abstractions — the typed deployment plan,
content-addressed release identity, the append-only deployment-event
store, the boundary lease, and the rollback state machine — are unusually
rigorous for pre-alpha software, and several of the load-bearing claims
were verified experimentally rather than taken on faith. Racing 20
concurrent `kubectl create` calls against the same boundary-lease
ConfigMap on a live k3d cluster produced exactly one winner, confirming
FEAT-072's mutual-exclusion claim is real, not aspirational. The rollback
state machine only moves the "current release" pointer after live cluster
state is independently re-verified. Kafka's ack-after-handle semantics are
implemented correctly, attempt metadata survives process death because
it's carried on the message rather than in memory, and `sol-jobs`'
`FOR UPDATE SKIP LOCKED` leasing is honest about being at-least-once
rather than falsely promising exactly-once. The Service/Worker/Function/
Jobs primitive boundary is genuinely coherent, enforced by the type
system in places (a plain `Worker.WORKER` cannot even express a retry
outcome), not just by convention.

Against that foundation, this review found a materially inconsistent
level of rigor once the boundary moves from "Sol's own control-plane
records" to "the infrastructure those records describe." The most
important example: every Kafka topic Sol ever creates is hardcoded to
`replication_factor:1` with no override anywhere in the call chain
(`framework/kafka-eio-service/lib/kafka_service_intf.ml:64`) — including
against a "durable" multi-broker Redpanda target, whose values file adds
no override of its own. Sol treats transport *security* as a forced,
explicit field on every Kafka config (`Kafka_security.t`, "Security on Day
1"); topic *durability* gets no equivalent treatment and can silently lose
acknowledged data on a single broker loss. Alongside that: no
PodDisruptionBudget is ever rendered for any workload, Terraform state for
both cloud modules defaults to local and unlocked, AWS RDS has no
multi-AZ toggle while the GCP module already has the equivalent, and
`sol deploy` never checks whether pending database migrations have been
applied before rolling out code that may depend on them. None of these
are subtle — each is a short, well-scoped fix, not a redesign.

**Bottom line:** I would not point real customer traffic at a
multi-replica or "durable" Sol deployment today without first closing the
Kafka-durability, PDB, and Terraform-state gaps — but nothing found here
requires reconsidering the plan/release/executor architecture itself. The
foundation is sound; the punch list is short, concrete, and additive.

## Production maturity assessment

### A — one team, ~10 services, real but modest traffic

**Sufficient:** primitive model (Svc/Worker/Fn/Jobs), scaffold → local dev
→ deploy → rollback DX, boundary-lease concurrency safety, rollback's
migration-boundary refusal, Kafka ack/retry/DLQ semantics, `sol-jobs`
transactional enqueue and lease recovery, pod security defaults
(non-root, seccomp, read-only rootfs) and default-deny NetworkPolicy
applied uniformly with no opt-out, dev/prod Helm-value parity.

**Blocks responsible use today:** the Kafka replication-factor-1 default
(a single operator can lose acknowledged data on a broker restart, not
just an outage), local/unlocked Terraform state the moment the AWS/GCP
modules are used for anything beyond throwaway experimentation, no PDB
the moment any service runs more than one replica, no migration-ordering
gate (an easy mistake for even one careful operator), and no liveness
probe on workers (a hung consumer is invisible).

**Can reasonably wait:** HPA/autoscaling (fixed capacity is a legitimate
small-scale choice as long as it's documented as such, not claimed as
elastic), image digest pinning, GitOps release-history parity, RBAC
starter manifests, deployment-event retention, audit-actor identity,
admission policy/image provenance.

### B — several teams, 50–100 workloads

Everything in A becomes mandatory (a forgotten migration-ordering step or
an under-replicated topic is far more likely across several engineers
than one careful operator). Additionally required: RDS/database HA parity
with GCP, deployment-event history retention and a trustworthy actor
identity, real HPA or an explicit documented fixed-capacity policy (not a
decision doc that contradicts the renderer), ResourceQuota/LimitRange or
an equivalent blast-radius boundary once multiple teams share a cluster,
and GitOps-mode release-history parity or an explicit, loud warning that
it doesn't exist. Environment isolation (DEC-016's fail-closed
same-cluster rejection) already holds up here and doesn't need rework.

### C — hundreds/thousands of workloads, multiple independent teams

No architectural decision found in this review blocks reaching C. The
namespace-per-(workspace, domain) scheme has room to add a team label
without renaming anything; the boundary lease and deployment-plan/executor
model are already designed to generalize (a future hosted executor is
meant to consume the same plan). What's missing at C is real tenancy
machinery that doesn't exist yet and isn't pretended to: per-team
RBAC/quotas, image provenance/signing admission policy, durable
cross-cluster audit trail, and a documented cluster/chart upgrade
procedure. These are additive scale features, not blockers to be resolved
before B ships.

## Findings

Ordered by production risk, not ease of implementation. The initial point-fix
ticket draft was reconciled into guarantee-oriented workstreams: availability
(AUDIT-080), release safety (AUDIT-069), state/access (AUDIT-072), data
durability (AUDIT-078), operational response (OBS-043), and the reconciliation
decision (DEC-027). AUDIT-075 through AUDIT-077 remain deferred findings.

### 1. Every Kafka topic is created with replication factor 1 — no override exists
- **Classification:** Defect / violated invariant (durability gets none of
  the "forced explicit field" treatment security already gets).
- **Severity:** High (Critical if it hits a real "durable" target's
  broker-loss event before it's fixed).
- **Maturity:** Blocks responsible use at A the moment a workload's data
  matters; unacceptable at B/C.
- **Evidence:** `framework/kafka-eio-service/lib/kafka_service_intf.ml:62-68`
  — `~replication_factor:1` is a bare literal, not a parameter;
  `cli/platform/components/redpanda/values-durable.json` is `{}`, so
  nothing at the infra layer compensates.
- **Failure scenario:** A broker in a "durable" multi-broker Redpanda
  target restarts or is lost; every topic's partitions on that broker are
  unavailable, and if the underlying disk is lost rather than just
  restarted, already-acknowledged messages are gone permanently with no
  replica to recover from.
- **Existing mitigation:** None found — the durable Helm profile changes
  broker count but nothing in application code uses it.
- **Existing ticket:** None (searched for "replication_factor" across
  `pipeline/tickets/`; all hits are unrelated Loki-ring issues,
  BUG-006/008/013).
- **Recommended action:** AUDIT-078 — make replication factor an explicit,
  required field per environment, matching `Kafka_security.t`'s pattern.

### 2. No PodDisruptionBudget is ever rendered
- **Classification:** Production-readiness gap.
- **Severity:** High.
- **Maturity:** A the moment any service runs >1 replica; mandatory at B/C.
- **Evidence:** Zero `PodDisruptionBudget` hits across the whole repo
  outside comments; `sol_cli_manifest_yaml.ml` renders Deployments/
  Rollouts/CronJobs with no PDB counterpart.
- **Failure scenario:** A routine node drain, cluster-autoscaler
  scale-down, or Kubernetes version upgrade evicts every replica of a
  service simultaneously — an outage caused by normal maintenance, not by
  any incident.
- **Existing mitigation:** None.
- **Existing ticket:** None.
- **Recommended action:** AUDIT-080 — implement the workload availability
  guarantee, including the required disruption behavior rather than treating a
  PDB as the contract.

### 3. Terraform state defaults to local, unlocked, for both cloud modules
- **Classification:** Production-readiness gap.
- **Severity:** High at B/C, Medium at A.
- **Evidence:** `cli/platform/infra/aws/main.tf:34-37` and
  `.../gcp/main.tf:35-37` both ship the remote-backend block commented
  out by default.
- **Failure scenario:** Two operators (or a human and CI) apply
  concurrently with no lock and corrupt state; losing the one machine
  holding local state loses the only record of what infrastructure
  exists, with no recovery short of manual `terraform import`.
- **Existing mitigation:** None — this is the one layer in the stack that
  doesn't get the rigor Sol's own release/deployment records do.
- **Existing ticket:** None.
- **Recommended action:** AUDIT-072 — parameterize and activate a real
  remote backend, with a one-time bootstrap script for the state
  bucket/lock table.

### 4. AWS RDS has no multi-AZ toggle; GCP Cloud SQL already has the equivalent
- **Classification:** Defect — inconsistent HA guarantee across the two
  "cloud-agnostic" providers for the one hard-to-replace stateful resource
  each provisions.
- **Severity:** High at B/C, Medium at A.
- **Evidence:** `cli/platform/infra/gcp/main.tf:141` —
  `availability_type = var.sql_high_availability ? "REGIONAL" : "ZONAL"`;
  no equivalent `multi_az` attribute exists on
  `cli/platform/infra/aws/main.tf`'s `aws_db_instance`.
- **Failure scenario:** An AZ outage on the AWS path takes down Postgres
  for every service depending on it, with no code path to have prevented
  it — unlike the GCP path, which can opt in today.
- **Existing mitigation:** Backup retention (7 days) and
  `storage_encrypted` are present and equivalent on both clouds; only HA
  diverges.
- **Existing ticket:** None.
- **Recommended action:** AUDIT-078 — decide the database availability/recovery
  guarantee, then add Multi-AZ only if that guarantee requires it.

### 5. `sol deploy`/`sol up` never check whether pending migrations have been applied
- **Classification:** Production-readiness gap.
- **Severity:** Medium (A), High (B).
- **Evidence:** `pg-eio`'s `Migration.apply` is correct in isolation, but
  no call site in `cmd_deploy.ml`/`cmd_up.ml` ever references `Migration`
  at all — `sol migrate` is a fully separate, manually invoked command
  (documented as deliberate in
  `docs/deployment/self-hosted-substrate-contract.md:73-74`, but not
  enforced).
- **Failure scenario:** New pods roll out and serve traffic against a
  stale or half-migrated schema; for a backward-incompatible migration
  this produces errors or, worse, silently incorrect writes during the
  rollout window.
- **Existing mitigation:** Migrations themselves are transactional and
  fail closed; the gap is purely about deploy-time ordering.
- **Existing ticket:** None (FRIC-012 solved migration-job *reachability*
  for RDS, not *ordering*).
- **Recommended action:** AUDIT-069 — refuse to deploy with pending
  migrations unless an explicit `--skip-migration-check` opt-out is
  passed.

### 6. HPA/autoscaling is a documented architecture decision, not an implemented capability
- **Classification:** Defect — `PRODUCT_ARCHITECTURE.md`'s DEC-008/010
  state hosted environments use KEDA/HPA/Karpenter/Aurora Serverless "by
  default"; no HPA (or any autoscaling primitive) is rendered anywhere,
  confirmed by a repo-wide grep and by `sol_cli_deployment_plan.ml:512-515`'s
  own comment: "no HorizontalPodAutoscaler is emitted anywhere today."
- **Severity:** Medium at A (fixed replicas is a legitimate small-scale
  choice), High at B/C (no automatic scale-out under load).
- **Failure scenario:** A traffic or Kafka-lag spike exceeds fixed
  replica count with nothing to react — manual on-call scaling or an
  outage, while the architecture doc implies this is already handled.
- **Existing mitigation:** BUG-004 (DONE) already tracks `sol.yml`'s
  `scale_min`/`scale_max` standing in as an interim fixed count and
  explicitly defers the HPA gap; INFRA-016/017 separately and rigorously
  studied shared-compute isolation (a different, adjacent question) with
  real experiments rather than speculation.
- **Existing ticket:** BUG-004 already owns the interim state honestly.
- **Recommended action:** No new ticket — reclassify DEC-008/010's
  language in `PRODUCT_ARCHITECTURE.md` as target architecture rather than
  current behavior, and let a real HPA/KEDA implementation ticket get
  filed when B-scale usage is closer (this is exactly the kind of item
  the review methodology says shouldn't be forced into existence early).

### 7. Background_worker Deployments get no liveness or readiness probe
- **Classification:** Defect / violated invariant (inconsistent with the
  shared lifecycle contract `-svc`/`-worker`/`-fn` otherwise share).
- **Severity:** Medium (A), High (B/C).
- **Evidence:** `sol_cli_manifest_yaml.ml`'s `probe_section` is populated
  only `if shape = Http_service`; `Background_worker` gets `""` in both
  the Deployment and Rollout render paths.
- **Failure scenario:** A hung/deadlocked Kafka consumer loop stays
  `Ready` forever; nothing restarts it automatically, and the only signal
  is an operator noticing a lag/metrics dashboard has stalled.
- **Existing mitigation:** None — `-svc` and `-fn` both have automated
  recovery signals; `-worker` is the one primitive without one.
- **Existing ticket:** None.
- **Recommended action:** AUDIT-080 — define worker availability inside the
  shared workload guarantee, then add the health mechanism that proves it.

### 8. `sol deploy --emit-to` (GitOps mode) gets none of Sol's release/rollback safety, silently
- **Classification:** Production-readiness gap, already partly
  acknowledged in DEC-018/FEAT-066 as an accepted scope boundary — the gap
  here is the missing warning, not the missing feature.
- **Severity:** Medium, High if a team adopts this path as primary without
  knowing.
- **Evidence:** `run_emit` never acquires the boundary lease or records a
  release; `Sol_cli_release.apply_mode`'s `Gitops` variant has no producer
  anywhere in the repo (confirmed by full grep).
- **Failure scenario:** A team on the documented "Exported Self-Managed"
  ownership lane later runs `sol releases`/`sol rollback` expecting
  history and gets nothing, discovering the gap during an incident.
- **Existing mitigation:** The scope decision itself is sound and
  documented in ticket bodies; only the runtime communication is missing.
- **Existing ticket:** DEC-018/FEAT-066 note the boundary; neither adds an
  emit-time warning.
- **Recommended action:** DEC-027 — decide whether GitOps is the production
  authority. A notice is sufficient only for a non-profile export lane.

### 9. `terminationGracePeriodSeconds` is never rendered, leaving it implicitly coupled to each primitive's own drain timeout
- **Classification:** Defect / violated invariant.
- **Severity:** Medium.
- **Evidence:** `sol-svc`'s `Service.run` implements a real drain-on-
  SIGTERM race against `drain_timeout_s`
  (`framework/sol-svc/lib/service.ml:355-373`), but no manifest ever sets
  `terminationGracePeriodSeconds`, relying on it happening to equal k8s's
  30s default. `docs/deployment/service-runtime-contract.md` already
  flags this explicitly.
- **Failure scenario:** The moment a `sol.toml` drain-timeout override
  ships (a natural next addition), a value longer than 30s means
  Kubernetes SIGKILLs before the app's own graceful drain finishes,
  silently truncating in-flight requests on every rolling deploy.
- **Existing mitigation:** None beyond the two values currently
  coincidentally matching.
- **Existing ticket:** None.
- **Recommended action:** AUDIT-080 — make drain behavior part of the workload
  availability guarantee rather than shipping the grace-period mechanism alone.

### 10. Deployment-event `actor` field is an arbitrary, unverifiable environment variable
- **Classification:** Defect / violated invariant (the field is marketed
  as provenance but can't function as one).
- **Severity:** Medium.
- **Evidence:** `sol_cli_deployment_attempt.ml:32` —
  `~actor:(Sys.getenv_opt "SOL_ACTOR")`, not derived from any verifiable
  identity.
- **Failure scenario:** Once credentials/CI runners are shared across a
  team (B), "who deployed this" cannot actually be trusted from this
  field — worse than having no such field, since it looks like an audit
  control without being one.
- **Existing mitigation:** None.
- **Existing ticket:** None.
- **Recommended action:** AUDIT-075 — prefer a verifiable CI/git identity
  when available, and label the source of the value honestly.

### 11. Deployment-event history has no retention and no durability outside the cluster
- **Classification:** Production-readiness gap.
- **Severity:** Medium.
- **Evidence:** Unlike release records (FEAT-072's `--keep-releases N`),
  `Sol_cli_deployment_store` prunes nothing — one ConfigMap per deploy
  attempt, forever.
- **Failure scenario:** Unbounded ConfigMap growth as deploy frequency
  rises, and total loss of "who deployed what when" if the cluster/etcd
  is ever lost or rebuilt.
- **Existing mitigation:** None.
- **Existing ticket:** None.
- **Recommended action:** AUDIT-076 — add bounded retention mirroring
  release retention; treat full external export as a separate, later
  initiative.

### 12. Image references are mutable tags; no digest pinning anywhere in the render path
- **Classification:** Production-readiness gap.
- **Severity:** Medium at B (Low at A, where the operator controls the
  registry directly).
- **Evidence:** `--image-tag` defaults to the git SHA (`cmd_deploy.ml:140`)
  but manifests render `image: <registry>/<tag>` with no `@sha256:`
  digest anywhere.
- **Failure scenario:** A compromised CI credential or registry account
  retags a SHA between build and review; a subsequent deploy or a
  restarting kubelet's re-pull runs different bytes than what was
  reviewed.
- **Existing mitigation:** Using the git SHA as the tag (rather than
  `latest`) is already better practice than most hand-rolled setups.
- **Existing ticket:** None found specifically for digest resolution at
  render time.
- **Recommended action:** Resolve `--image-tag` to a digest at plan/render
  time before B-scale adoption; not urgent for A. Not separately ticketed
  here — reasonable to bundle with any future registry/build-pipeline
  hardening work rather than as a standalone change.

### 13. No drift detection, and `infra/aws`/`infra/gcp`/`infra/base` are separate Terraform states with manual cross-wiring
- **Classification:** Production-readiness gap.
- **Severity:** Medium (A), High (B/C).
- **Evidence:** `cli/platform/infra/base/variables.tf` repeatedly and
  honestly documents the manual `-var` wiring needed between the two
  states.
- **Failure scenario:** A partial apply across the two states, or an
  incident-time need to reconstruct the wiring under pressure, has no
  automated reconciliation and no written runbook.
- **Existing mitigation:** The seam is documented, not hidden.
- **Existing ticket:** None.
- **Recommended action:** Either link the states with
  `terraform_remote_state` or write the manual runbook down explicitly;
  reasonable to defer past A.

### 14. The boundary lease's stale-takeover (CAS) path is untested against a live API server
- **Classification:** Production-readiness gap (test coverage only — the
  mechanism was independently reasoned to be correct).
- **Severity:** Low–Medium.
- **Evidence:** `test_boundary_lease.ml`'s own header states the CAS path
  needs a live cluster and isn't exercised; this review confirmed the
  *first-acquire* race live but did not additionally race the
  *stale-takeover* replace path.
- **Recommended action:** A cheap integration test racing
  `replace --resource-version`, gated like the repo's other live-cluster
  tests. Not urgent — the decision logic itself is unit-tested and sound.

### 15. Release-record validation reports "corrupt" when the real cause is a stale `encoding_version`
- **Classification:** Defect (diagnosability, not data-safety).
- **Severity:** Low.
- **Evidence:** `Sol_cli_release.validate` uses one error message for both
  a genuinely tampered record and a record written under an older,
  since-changed `encoding_version` (already happened once, BUG-026).
- **Recommended action:** AUDIT-077 — distinguish the two cases in the
  error message; no change to the fail-closed behavior itself.

### 16. No advisory when Alertmanager still has no real notification receiver
- **Classification:** Scale/maturity feature (the underlying null-receiver
  default is a deliberate, sound, already-documented design decision from
  OBS-040 — Sol correctly doesn't run alerting infra on a customer's
  behalf).
- **Severity:** Low.
- **Evidence:** `cli/platform/infra/base/main.tf`'s comment confirms the
  null receiver is intentional; nothing warns an operator it's still
  unconfigured.
- **Recommended action:** OBS-043 — require and test the alert-to-owner response
  loop; a null-receiver advisory alone is not production evidence.

### Noted but not ticketed (premature, scale-appropriate, or already adequately tracked)
- No ResourceQuota/LimitRange or team-ownership field anywhere — real gap
  at B, but additive (the namespace scheme has room for a team label
  without renaming) and not worth building ahead of an actual multi-team
  pilot.
- No image provenance/signing/SBOM story — normal for A/B, worth one line
  in the substrate-contract doc acknowledging the gap for C rather than a
  ticket now.
- No RBAC least-privilege starter manifest for Sol's own required cluster
  permissions — cheap documentation gap, not urgent.
- `sol-jobs`'s failed-job table has no purge/requeue CLI, only raw SQL —
  defensible boundary (an app-owned table, not Sol-provisioned infra)
  unless a real workload demands it.
- No documented cluster/Helm-chart upgrade procedure — real gap at B, but
  version pinning itself (see strengths) is already solid, and no
  operational or provider version-skew story is required simply to reach
  A.

## Architecture strengths — do not rework these

1. **Boundary lease (FEAT-072) — experimentally confirmed correct.**
   Racing 20 concurrent `kubectl create` calls against the same
   ConfigMap name on a live k3d cluster produced exactly one winner; the
   stale-lease takeover uses a `resourceVersion` compare-and-swap, not a
   blind overwrite.
2. **Rollback state machine (FEAT-075/DEC-018).** Every step before
   apply is read-only; the "current" pointer only moves after live
   cluster state is independently re-verified to match. The
   migration-boundary check refuses rollback across any migration with no
   declared safe disposition, with no "assume expand" fallback.
3. **Content-addressed release identity + append-only deployment events
   (FEAT-069/070/071).** A single, non-duplicated projection computes the
   release id; a no-op redeploy produces no new release; corrupted or
   missing records fail closed rather than silently presenting a partial
   history as complete.
4. **Kafka reliability semantics.** Ack strictly after handler completion
   (correct at-least-once); attempt metadata travels on the message, not
   in worker memory, so a killed process loses no retry state; FEAT-078's
   retry-policy unification shares one backoff computation across both
   strategies and closes the DLQ-less dead-letter gap by failing closed
   instead of ack-and-drop.
5. **Kafka ordering semantics are documented honestly**, including the
   places `Retry_topics` does *not* preserve completion order — more
   rigor than most production Kafka frameworks bother with.
6. **`sol-jobs` (FEAT-077).** Real transactional enqueue (same DB
   transaction as the business write), correct `FOR UPDATE SKIP LOCKED`
   leasing with crash recovery, and an honest at-least-once contract that
   never claims exactly-once.
7. **obs-eio's error boundary.** A down Loki/Prometheus/Tempo degrades to
   "telemetry silently not delivered, visible via stderr," never crashes
   the app — consistent with the documented three-layer visibility model.
8. **Service/Worker/Function/Jobs primitive boundary.** Cleanly
   non-overlapping, partly type-enforced (a plain `Worker.WORKER` cannot
   express a retry outcome at all), with a real, stated decision rule for
   choosing Kafka vs. Postgres jobs (ordering/partition-key dependence vs.
   independent units of work).
9. **Escape hatches are real, not aspirational.** `[infra.rollout]`
   renders genuine Argo canary/blue-green resources with validated
   parameters; non-overridable security invariants (non-root, no
   privilege escalation, read-only rootfs, seccomp) hold even through
   every escape-hatch level.
10. **Pod security and NetworkPolicy defaults are uniform and
    non-optional** across every rendered workload — stricter than most
    hand-written manifests, with no opt-out.
11. **Environment isolation (DEC-016) fails closed.** Two environments
    resolving to the same cluster is a hard deploy-time error, not a
    convention — this is what makes it safe that environment names never
    appear in internal resource naming.
12. **Terraform/Helm version pinning is a real, generalized policy**, not
    a one-off fix: every provider and every `helm_release` pins an exact
    version, extending BUG-008's original one-off Grafana pin into a
    repo-wide practice.
13. **"Dev mirrors prod exactly" is substantiated, not just claimed** — the
    same Helm charts and shared base-values files render at both scales,
    verified by diffing the actual values files, not by trusting the
    doc's prose.
14. **`-fn`/long-lived-workload isolation is backed by real controlled
    experiments (INFRA-016/017)**, not speculative hardening — exactly
    the right evidence-over-speculation discipline.
15. **Secrets never appear in release records or GitOps output** —
    verified by tracing the actual data flowing into the content-addressed
    record, not by trusting a comment.
16. **Language-neutral distribution is a first-class, tracked concern**
    (DEC-022/023/025) — TypeScript's npm-publish path was independently
    verified end-to-end; the OCaml git-pin interim state is an honest,
    explicitly tracked tradeoff (RELEASE-005), not a silent gap.

## Missing evidence

Distinguished from confirmed gaps — these are claims this review could
not establish either way in the time/sandbox available:

- Whether a ServiceAccount for one service can read a sibling service's
  Secret within the same namespace (RBAC scoping within a namespace was
  not traced).
- The full egress ruleset of the generated NetworkPolicy beyond DNS and
  the Redpanda namespace.
- GCP Workload Identity's rotation/trust-boundary documentation parity
  with the AWS IRSA writeup.
- A true end-to-end concurrent `sol deploy` (full plan+apply, not just
  the lease primitive) against a live cluster, and a physical CLI-process-
  kill-mid-apply test — both reasoned correct from the code's structure
  (no partial release record is possible by construction) but not
  physically exercised.
- A live Kafka-broker-kill-mid-message experiment (redelivery was
  verified by tracing ack ordering, not by an observed kill).
- Live credential-rotation behavior (IRSA has no in-tree consumer today;
  Postgres password rotation mid-run was not tested against a live
  partition).
- Whether two different workspaces' concurrent deploys to the same
  cluster can race on shared cluster-scoped resources (a `ClusterIssuer`,
  an `IngressClass`) — the boundary lease is scoped per-workspace, and
  this cross-workspace question wasn't traced.
- TypeScript-side scaffold/framework version-pinning parity with the
  OCaml side, and whether `examples/pluto/app/demo_ts` has actually been
  cut over from local packages to the published `@sol-fab/*` packages
  (DEC-023 lists this as a remaining step; not independently confirmed
  here).
- Kafka schema-registry compatibility-mode (BACKWARD/FORWARD/FULL)
  enforcement across app releases.
- Real `terraform apply` behavior against live AWS/GCP (all Terraform
  findings here are static-code-verified); WORK_SUMMARY records one real
  prior live AWS smoke test that did catch a real gap (undersized-node
  OOMKill), which is evidence Sol has been live-tested at least once, not
  zero evidence.

## Recommended roadmap

**1. Architectural corrections:** none required. No finding in this
review calls the plan/release/executor architecture, the primitive
boundary, or the Kafka/jobs programming-model split into question.

**2. Maturity-A production blockers (do these before trusting any real
workload's data to Sol):**
1. AUDIT-078 — application-data durability and recovery.
2. AUDIT-080 — workload availability semantics and failure behavior.
3. AUDIT-072 — recoverable state and scoped production identities.
4. AUDIT-069 — production release safety.

**3. Production hardening (before treating GitOps/multi-operator use as
routine):**
1. DEC-027 — production reconciliation ownership.
2. OBS-043 — alert delivery, ownership, SLOs and runbooks.
3. AUDIT-075 — verifiable deployment-actor identity (deferred beyond A).
4. AUDIT-076 — deployment-event retention (deferred beyond A).
5. AUDIT-077 — stale-encoding-version error message (deferred cleanup).
6. Terraform cross-state drift/runbook, image digest pinning, boundary-
   lease CAS live test (all noted above, no ticket forced).

**4. Maturity-B capabilities:** reclassify DEC-008/010's autoscaling
language against reality (or build a real HPA/KEDA path once B-scale
traffic justifies it), team/ownership + quota model, RBAC least-privilege
starter manifests, image provenance/admission policy groundwork.

**5. Maturity-C considerations:** durable cross-cluster audit export,
documented cluster/chart upgrade procedure and version-skew policy,
per-team tenancy enforcement beyond namespace convention. No current
architectural decision was found to block reaching this level.
