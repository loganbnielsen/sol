# Sol production application-platform contract review — 2026-09-16

## Executive assessment

Sol has a coherent **application packaging and deployment vocabulary**, but it
does not yet define a complete production **application-platform contract**.
The distinction matters. `svc`, `worker`, and `fn`; the workspace/domain model;
typed deployment plans; content-addressed releases; explicit targets; generated
security contexts; release inspection; rollback guards; and shared telemetry
identity form a credible foundation. Kubernetes remains visible in the right
places, and the plan/render/executor direction is the correct seam for local,
customer-cloud, GitOps, and a future hosted control plane.

What is not yet coherent is the promise made after a plan is rendered. Sol does
not presently define or enforce a production class with availability,
durability, scaling, identity, recovery, alert delivery, and upgrade guarantees.
It sometimes describes capabilities that are decisions or aspirations as if
they were current platform behavior. The most important example is elasticity:
the architecture says hosted environments use KEDA/HPA/Karpenter and Aurora
Serverless by default, while no HPA is rendered, no KEDA or Karpenter is
installed, and AWS provisions fixed RDS. Similar gaps exist between "durable"
and single-replica platform components, "production" and local Terraform state,
and "observability" and an alert that reaches no human.

I would not put customer-facing production on Sol today. The shortest credible
path is not a larger feature list. It is to define one supported **single-region
production profile**, make its invariants executable, and prove restore,
rollout, node-loss, dependency-loss, and operator-response paths against it.

The architecture is salvageable without a rewrite. The typed plan is the right
spine. The current direct `kubectl apply` executor can serve small production
once the contract is narrowed and hardened. The future hosted design is still a
direction, not an implemented operating model, and should not yet constrain the
self-hosted contract beyond preserving the plan/executor boundary.

## Central answers

### Does Sol define a coherent, defensible contract over Kubernetes?

**Partly.** It defines a defensible desired-state compilation contract:

```text
workspace source
  -> neutral workload/resource intent
  -> typed deployment plan and release identity
  -> Kubernetes/GitOps artifacts
  -> executor
```

It also has a useful runtime vocabulary: HTTP services are replaceable request
handlers, workers are at-least-once Kafka consumers, and functions are finite
Kubernetes executions. The language-neutral direction is credible: deployment
identity is not defined by OCaml or TypeScript.

It does **not** yet define a defensible operating contract for the resulting
system. A user cannot answer, from a target/profile alone:

- which failures the platform tolerates without outage or data loss;
- which components are durable and how they are restored;
- what scales automatically, on which signal, and within which limits;
- which identities may deploy, read secrets, or call dependencies;
- who reconciles drift and partial failure after a direct deploy;
- which alerts page whom, and what the first response action is;
- which upgrades are supported and how rollback is performed;
- which SLOs the platform itself promises.

### Is the architecture a sound foundation for real workloads?

**Yes for continued development; no for current production trust.** The plan,
release, executor, telemetry taxonomy, migration guard, and boundary lease are
good foundations. Kubernetes-native workload primitives are a sound choice.
No current decision forces a rewrite before maturity A or B.

At organization scale, the per-customer-cluster hosted decision creates a high
fixed cost and fleet-management burden, but it is not technically fatal. The
more serious C-level issue is that no durable hosted control-plane model exists
yet for desired-state reconciliation, fleet upgrades, per-customer Terraform
state, IAM scoping, audit, quotas, or break-glass operations. Those are not
ordinary executor details; together they are the hosted product.

### Refined production-profile model

Environment identity and production capability are separate. A target named
`prod` need not claim the production profile, and selecting an environment must
not silently opt into one. A target explicitly selects a profile such as
`production-single-region`.

The profile is a policy and compatibility boundary, not a giant deployment-plan
record:

```text
application requirements        target capabilities and policy
  availability                    cluster failure domains
  artifact identity               data-service durability
  resource requirements           state/access model
  storage durability              alert delivery
  application configuration       supported versions
             \                         /
              \                       /
               -> profile validation
                        |
                typed deployment plan
                        |
                      render
```

The application states portable requirements. The target states what its
substrate and operators provide. The selected profile defines the minimum
compatible combination and the conformance tests that prove it. Provider and
Kubernetes implementation details stay below this boundary.

## Maturity verdict

| Level | Verdict | Why |
| --- | --- | --- |
| A — one team, ~10 workloads | **Not responsible yet** | The application path is plausible, but there is no proven production profile, HA workload placement, durable Kafka contract, tested restore path, immutable artifact requirement, or alert delivery. A disciplined team could pilot non-critical traffic only by supplying these outside Sol. |
| B — several teams, 50–100 workloads | **Not close operationally** | In addition to A, Sol lacks team/role boundaries, quotas, workload identity, policy enforcement, automated scaling, fleet-safe upgrades, and an explicit drift/reconciliation ownership model. Shared credentials and convention-derived ownership do not form a multi-team control plane. |
| C — hundreds/thousands | **Architecturally possible, not designed in enough detail** | The neutral plan/executor model can scale conceptually. Per-customer clusters improve isolation but create a fleet product. Account-wide control-plane IAM, quotas, state isolation, regional strategy, reconciliation, metering, audit, and upgrade waves need explicit designs before hosted implementation. |

## Production maturity findings

### 1. Sol has no executable definition of “production”

- **Classification:** Fundamental contract gap
- **Severity:** Not severity-rated; production-readiness blocker. Unsafe
  configurations admitted by the missing contract are rated separately below.
- **Maturity:** Blocks A; foundational for B/C
- **Evidence:** The same target path can select one replica, a single NAT
  gateway, zonal database, single-replica Loki, replication-factor-one Kafka
  topics, local Terraform state, and a null Alertmanager receiver. These are
  independent knobs rather than a validated production profile.
- **Failure scenario:** A team believes `sol deploy prod/...` implies a supported
  posture. A node/AZ/broker loss or laptop/state-file loss causes an outage or
  unrecoverable control-state ambiguity even though the deployment was valid.
- **Existing mitigation:** Secure container defaults, explicit resources,
  backups on managed databases, durable-observability mode, deployment/release
  records, and honest README language saying Sol is not production-stable.
- **Existing work:** No ticket owns the cross-cutting contract. Individual work
  exists in FEAT-050, FEAT-083, INFRA-017, OBS-043, and the infrastructure
  modules, but completing them would still not define a production class.
- **Recommended action:** Define exactly one `production-single-region` profile
  with required invariants and a conformance command. Reject a production target
  that does not satisfy it. Keep provider-specific implementation below that
  neutral profile.

### 2. Production reconciliation ownership is not explicitly decided

- **Classification:** Architecture decision
- **Severity:** Medium
- **Maturity:** Must be decided for A; the sophistication required increases at
  B/C
- **Evidence:** Direct mode renders a change set and invokes `kubectl apply`.
  The boundary lease prevents competing Sol mutations, and release/deployment
  ConfigMaps preserve useful history, but no controller reconciles drift after
  the command exits. GitOps delegates reconciliation to Argo/Flux, but that is a
  different ownership model.
- **Failure scenario:** An out-of-band mutation changes or deletes one member of
  the recorded release. Kubernetes reconciles each remaining object, but no Sol
  mechanism currently establishes whether the *collection* still matches the
  release. Operators may trust stale release metadata unless status/check detects
  the divergence.
- **Existing mitigation:** Render-all-before-apply, boundary leases, rollout
  waits, failure events, content-addressed release records, and rollback
  verification are unusually good for a CLI deployer.
- **Existing work:** The latest code-layer audit recommends a plan-to-result
  execution boundary. No existing ticket decides whether production direct mode
  is intentionally imperative or merely an interim GitOps/control-plane path.
- **Recommended action:** Make an explicit decision; continuous Sol-level
  reconciliation is not an axiom. A coherent maturity-A imperative contract is:
  render the complete desired state, acquire the mutation lease, apply, wait,
  verify, and record success; after deploy Kubernetes owns resource-level
  reconciliation, while `sol status/check` detects divergence from the recorded
  release and Sol does not silently undo out-of-band changes. GitOps is the
  alternative ownership model, not automatically the production default.

### 3. Durability classes are conflated and partly unsafe

- **Classification:** Fundamental reliability gap
- **Severity:** High overall; Critical where replication-factor-one permits loss
  of acknowledged business events
- **Maturity:** Blocks A; scales in consequence at B/C
- **Evidence:** Kafka topic creation hard-codes replication factor 1 and the
  durable Redpanda values add no production overrides. AWS RDS has backups but
  no Multi-AZ setting; GCP defaults Cloud SQL HA off. FEAT-083 correctly records
  that persistent workload identity and replica/storage semantics are undefined.
  Separately, durable Loki remains one monolithic replica with replication
  factor 1, and Terraform/Sol release records have their own persistence paths.
- **Failure scenario:** Loss or maintenance of a broker/node/AZ stops event
  processing or loses acknowledged business events; a zonal database failure
  takes the application down; replicas sharing a PVC behave according to
  incidental CSI semantics. Loss of telemetry affects diagnosis, not business
  correctness, and must not be assigned the same RPO/RTO by default.
- **Existing mitigation:** Managed database encryption, seven-day backup/PITR
  configuration, deletion protection, optional object storage for telemetry,
  and an explicit local/non-durable mode.
- **Existing work:** FEAT-083 addresses workload persistence semantics, not
  platform data-service durability. No open work defines Kafka replication,
  database HA, backup verification, or restore drills as one guarantee.
- **Recommended action:** Define and test three separate durability contracts:
  application data (Postgres, Kafka, application volumes), platform/control
  state (Terraform and Sol release/deployment records), and telemetry (logs,
  traces, metrics). Give each its own RPO/RTO and degradation behavior. For A,
  require explicit Postgres availability/restore expectations, replicated Kafka
  with quorum-safe settings, and restore tests. Telemetry may legitimately have
  weaker retention and availability.

### 4. Availability is expressed as replica count, not as a guarantee

- **Classification:** Reliability implementation gap exposing a contract gap
- **Severity:** High
- **Maturity:** Blocks A for services with availability expectations; required B
- **Evidence:** Workloads render replicas and rolling strategy, but no
  PodDisruptionBudget, topology spread/anti-affinity, startup probe, or explicit
  termination grace. Default replicas are one. A replica count greater than one
  does not ensure placement across nodes or zones.
- **Failure scenario:** Both replicas land on one node; drain or node failure
  removes all capacity. A slow-starting service is killed by liveness checks.
  Kubernetes' default 30-second termination grace races the runtime's default
  30-second drain.
- **Existing mitigation:** Readiness/liveness probes for services, rolling
  deployments, graceful shutdown in framework runtimes, resource requests and
  limits, and optional Argo Rollouts.
- **Existing work:** No open ticket covers the availability unit as a whole.
- **Recommended action:** Define availability requirements by promised failure
  tolerance: `single`, `node-failure-tolerant`, and later
  `zone-failure-tolerant`. Render the minimal native controls for each and test
  node drain, pod eviction, rollout, and slow startup. Avoid ambiguous topology
  names and do not expose every Kubernetes knob.

### 5. Elasticity is a recorded decision, not a current capability

- **Classification:** Contract/documentation contradiction
- **Severity:** High
- **Maturity:** A can use fixed capacity; blocks B and the hosted promise
- **Evidence:** DEC-010 and PRODUCT_ARCHITECTURE say hosted uses KEDA, HPA,
  Karpenter, and Aurora Serverless. Source inspection finds no HPA output;
  `sol.yml` min/max resolves to a fixed replica count; AWS uses a managed node
  group with fixed desired size and fixed RDS. Merely setting ASG min/max does
  not install a cluster autoscaler.
- **Failure scenario:** A traffic or Kafka-lag spike exceeds fixed replicas.
  Pods may be unschedulable because no node scaler reacts, while the product
  contract implies elasticity exists.
- **Existing mitigation:** Explicit resource sizing, configurable replicas, GKE
  Autopilot, and INFRA-017's careful characterization of shared compute.
- **Existing work:** DEC-010 records the intended design; INFRA-017 studies
  isolation, not autoscaling. No implementation ticket owns the end-to-end
  scaling loop.
- **Recommended action:** Reclassify DEC-010 as target architecture. For A,
  require fixed-capacity headroom and document it. Before B/hosted, add one
  service scaling signal and one worker-lag signal, node capacity scaling, limits,
  stabilization behavior, and load tests. Avoid a generic scaling DSL first.

### 6. Artifact identity and supply-chain policy are below the release model

- **Classification:** Security/release integrity gap
- **Severity:** High
- **Maturity:** Blocks responsible A promotion/rollback; required B/C
- **Evidence:** Release identity is content-addressed over the plan, but workload
  images are normally mutable tags and ECR explicitly permits mutable tags.
  Scan-on-push exists, but there is no evidence of a deploy gate on findings,
  signature/provenance verification, or SBOM policy.
- **Failure scenario:** A tag is overwritten after approval. A rollout or
  rollback pulls different bytes while preserving the apparent release intent;
  a vulnerable image is scanned but still deployed.
- **Existing mitigation:** ECR scanning, release records, CI, hardened container
  security contexts, and GitOps artifact emission.
- **Existing work:** FEAT-050 is the correct root fix for digest references.
  FEAT-053 separates build-time secrets. DEC-016 describes hosted build
  isolation, but the hosted builder does not exist.
- **Recommended action:** Make digest pinning mandatory in production and record
  the digest per workload. Next require provenance from the authorized builder
  and an explicit vulnerability-policy result; signatures can follow when more
  than one builder/trust domain exists.

### 7. The security boundary stops at pod hardening and network intent

- **Classification:** Security architecture gap
- **Severity:** High
- **Maturity:** A can compensate manually; blocks B/C
- **Evidence:** Pods are non-root, seccomp-constrained, read-only, and covered by
  NetworkPolicy. However every workload gets a ServiceAccount without evidence
  that token automount is disabled, service-to-service auth uses a shared API-key
  convention, cloud workload identity is not an application contract, and no
  admission policy enforces generated invariants against later mutation.
- **Failure scenario:** One compromised pod obtains ambient Kubernetes
  credentials or a shared internal credential and impersonates another service.
  A multi-team operator weakens a manifest outside Sol with no admission denial.
- **Existing mitigation:** Per-workload ServiceAccounts, namespace separation,
  NetworkPolicy, Secret/ExternalSecret support, route-level auth types, IRSA for
  platform components, and single-customer hosted clusters by decision.
- **Existing work:** No current ticket defines workload identity, per-service
  authorization, token posture, admission policy, or rotation as one contract.
- **Recommended action:** For A, disable service-account token automount unless
  declared and prove secret rotation. For B, define workload identity and
  service authorization independent of language/provider, plus admission rules
  for the small set of invariants Sol claims.

### 8. Infrastructure state and administrative access are development-shaped

- **Classification:** Operational/security gap
- **Severity:** Critical for B; High for A
- **Maturity:** Blocks shared operation at A/B; foundational C
- **Evidence:** AWS and GCP remote-state backends are commented examples, not a
  provisioned contract. State contains database credentials. EKS grants the
  cluster creator admin and exposes a public control-plane endpoint. DEC-008
  requires per-customer state and scoped hosted IAM, but neither exists.
- **Failure scenario:** Two operators apply from different local states, a laptop
  is lost, state containing credentials leaks, or broad control-plane IAM mutates
  the wrong customer. Recovery may require import/reconstruction during an
  incident.
- **Existing mitigation:** Sensitive Terraform variables/outputs, private worker
  nodes/databases, and DEC-008's correct future requirements.
- **Existing work:** DEC-008 covers hosted intent only. No current ticket makes
  remote locked state, encryption, backup, and least-privilege administrative
  access mandatory for customer-cloud production.
- **Recommended action:** Treat state backend and access bootstrap as part of the
  target, not documentation comments. Production provisioning must fail without
  locked encrypted remote state, named operator/CI roles, audit logging, and a
  tested state-recovery procedure.

### 9. Observability exists; incident response does not yet form a closed loop

- **Classification:** Operational readiness gap
- **Severity:** High
- **Maturity:** Blocks A
- **Evidence:** Sol has strong labels, dashboards, logs, metrics, traces, release
  events, and status commands. Alertmanager deliberately routes to a null
  receiver. There is no repository evidence of platform SLOs, paging ownership,
  runbooks tied to alerts, synthetic availability checks, or incident exercises.
- **Failure scenario:** Error rate or restart-loop alerts fire only in a UI no one
  is watching. The first customer report is the detection mechanism; responders
  improvise restore/rollback steps under pressure.
- **Existing mitigation:** Prometheus rules, Alertmanager, Grafana, managed
  resource dashboards, release-correlated logs, rollback and status commands.
- **Existing work:** OBS-043 wires one PagerDuty example but is scoped as a demo
  integration and is blocked on credentials; it does not define the response
  contract.
- **Recommended action:** Define a minimal platform SLO set, required paging
  route, ownership metadata, and one-page runbooks. Run game days for failed
  rollout, DB unavailability, Kafka lag, node loss, and telemetry loss. Alert
  delivery must be a conformance check, not an optional dashboard feature.

### 10. Lifecycle compatibility and upgrades are not a platform guarantee

- **Classification:** Operational architecture gap
- **Severity:** High
- **Maturity:** A can pin manually; blocks B/C
- **Evidence:** Provider/chart versions are pinned in source and framework
  distribution is unfinished (DEC-025/RELEASE-005). There is no declared
  Kubernetes/provider version matrix, chart upgrade policy, control-plane/data
  migration protocol, skew policy, or fleet upgrade process.
- **Failure scenario:** A cluster/chart/framework upgrade breaks generated
  manifests, CRDs, telemetry, or runtime compatibility. Rollback of application
  code cannot undo infrastructure or data-format changes.
- **Existing mitigation:** Pinned provider/chart versions, CI builds/tests,
  migration dispositions, and release rollback guards.
- **Existing work:** DEC-025 and RELEASE-005 address OCaml distribution/versioning
  but not substrate/runtime compatibility. Existing release tickets do not own a
  platform upgrade contract.
- **Recommended action:** Publish a small compatibility matrix and N/N-1 upgrade
  policy. Build an upgrade conformance run from the previous supported profile
  to the next with workload continuity and rollback checkpoints. C later needs
  canary waves and fleet inventory.

### 11. The multi-team ownership model is taxonomy, not authorization

- **Classification:** Governance/isolation gap
- **Severity:** High
- **Maturity:** Not needed for A; blocks B/C
- **Evidence:** Workspace/domain/service labels and namespaces express ownership,
  but repository evidence does not show team RBAC, scoped deploy permissions,
  quotas, approvals, policy exceptions, or auditable break-glass workflows.
- **Failure scenario:** Any team/CI credential capable of deploying the workspace
  can alter another domain, consume shared capacity, read shared operational
  data, or trigger a broad rollback.
- **Existing mitigation:** Domain-derived namespaces, ServiceAccounts,
  NetworkPolicies, release provenance, and strict environment targets.
- **Existing work:** DEC-016 defines environment isolation; it does not define
  team authorization. FEAT-058 adds cluster identity defense-in-depth but not
  RBAC.
- **Recommended action:** Before B, define principals and allowed operations at
  workspace/environment/domain boundaries; enforce them in CI/GitOps and the
  cluster. Add quotas and ownership to alerts/releases. Do not invent a custom
  policy language before native RBAC plus repository protections prove
  insufficient.

### 12. The hosted model is a product architecture, not an implemented lane

- **Classification:** Future architectural risk
- **Severity:** Not an A blocker; Critical before hosted customers/C
- **Maturity:** C/hosted
- **Evidence:** Decisions choose per-customer clusters/VPCs in one Sol AWS
  account and a future hosted executor, but there is no hosted control plane,
  reconciler, builder isolation, per-customer state service, metering, fleet
  inventory, regional failover, support boundary, or emergency-access system.
- **Failure scenario:** A control-plane credential or provisioning bug has
  account-wide customer blast radius; cluster versions drift; quota exhaustion
  blocks onboarding or recovery; no authoritative service knows what should be
  running across the fleet.
- **Existing mitigation:** Strong decisions to keep one application model,
  isolate customers by substrate, use per-customer state, scope IAM, and avoid
  prematurely freezing a hosted API.
- **Existing work:** DEC-002/008/010/016/019 describe intent. Their proposed
  safeguards are not implemented and should not be counted as mitigation.
- **Recommended action:** Keep hosted out of the A roadmap. When resumed, design
  the control plane around desired-state reconciliation, per-customer state and
  credentials, immutable build artifacts, fleet inventory/upgrade waves,
  metering/quotas, and audited break-glass access. Revisit the cost/isolation
  tradeoff with real unit economics before locking per-customer EKS as the only
  tier.

## Architectural strengths worth preserving

1. **Typed plan as the contract spine.** This is the correct neutral boundary;
   strengthen it instead of adding command-specific behavior.
2. **Explicit target selection.** No ambient production destination is the
   right safety posture.
3. **Release versus deployment-attempt identity.** The distinction is
   operationally mature and supports trustworthy diagnosis.
4. **Language-neutral deployment identity.** OCaml and TypeScript packages may
   differ; workload, telemetry, retry, and deployment semantics should not.
5. **Kubernetes-native execution.** Deployments, Jobs/CronJobs, Services,
   NetworkPolicies, Secrets, and GitOps are defensible substrate choices.
6. **Honest escape hatches.** Generated artifacts and exported self-managed mode
   are valuable, provided responsibility transfer is explicit.
7. **Refusal to prematurely build hosted APIs.** Stabilizing the factory
   contract first is the right sequencing.

## Claims not established by this review

- **Not verified:** live AWS or GCP behavior on 2026-09-16. Prior dogfood
  reports are evidence, but this pass did not provision cloud infrastructure.
- **Not verified:** restore from RDS/Cloud SQL backup, Redpanda loss/recovery,
  Loki/Thanos recovery, or Terraform state-loss recovery. Repository config is
  not proof of recoverability.
- **Not verified:** zero-downtime node drains, AZ loss, control-plane upgrade,
  cluster upgrade, or high-load rollout behavior.
- **Not verified:** effective cloud IAM permissions, Kubernetes RBAC, audit-log
  retention, or secret-manager rotation in a live customer cluster.
- **Not verified:** Kafka delivery behavior under broker failure or long outage,
  including retry/DLQ capacity and poison-message operations.
- **Not verified:** TypeScript's end-to-end CI path; FEAT-087 explicitly records
  that it is manually proven but not continuously exercised.
- **Not implemented, rather than merely unverified:** hosted control plane,
  hosted builder, HPA/KEDA/Karpenter path, application workload identity,
  multi-team authorization, and a production profile/conformance gate.

Static validation performed for this review: `dune build @all` and
`dune runtest` passed. Static success does not establish the operational claims
above.

## Recommended roadmap

### 1. Architectural corrections

1. **Write the production contract before adding mechanisms.** Define one
   single-region profile that relates portable application requirements to
   target capabilities/policy and names the conformance evidence required.
   Keep state backend, alert routing, IAM, and supported cluster versions on the
   target side rather than inflating the application plan.
2. **Decide reconciliation ownership.** Choose and document either the disciplined
   imperative contract (deploy-time verification plus later drift detection) or
   continuous GitOps reconciliation. Both are legitimate; do not accidentally
   promise the latter while implementing the former.
3. **Make data and workload semantics explicit.** Finish FEAT-083 at the model
   level and add resource durability classes. Keep provider/Kubernetes fields
   out of the public contract unless they express unavoidable semantics.
4. **Correct documentation status.** Separate `implemented`, `experimentally
   validated`, `decided`, and `future`. In particular, autoscaling and hosted
   claims must stop reading as current behavior.

### 2. Maturity-A production blockers

1. Immutable image digests in production (FEAT-050).
2. Locked encrypted remote Terraform state and least-privilege deploy/admin
   identities.
3. A `node-failure-tolerant` workload policy with placement/PDB/startup/drain
   behavior.
4. Separate durability contracts: application data, platform/control state, and
   telemetry; replicated Kafka and successful database restore drills receive
   the strongest A-level attention.
5. A required alert receiver, platform SLOs, ownership, and incident runbooks.
6. A production conformance suite exercising deploy, failed deploy, rollback,
   node drain, dependency loss, backup restore, credential rotation, and alert
   delivery.
7. Publish/support the framework distribution and compatibility story
   (DEC-025/RELEASE-005), so a production workspace is reproducible outside the
   Sol checkout.
8. Put one non-critical workload through the profile and stop adding maturity-B
   machinery until real operation exposes the next constraint.

### 3. Production hardening toward B

1. Workload identity, per-service authorization, disabled ambient tokens, and
   secret rotation guarantees.
2. Team/environment/domain RBAC, quotas, approval boundaries, audit retention,
   and break-glass procedures.
3. Service and worker autoscaling plus node-capacity scaling, with bounded load
   tests and cost controls.
4. Supported upgrade matrix and N/N-1 conformance; progressive infrastructure
   upgrade procedure.
5. Capacity forecasting for Kafka/Postgres/telemetry and explicit saturation
   signals.
6. Policy enforcement for the few invariants Sol promises (artifact digest,
   pod security, resource declarations, approved registries), preferably with
   native admission controls.

### 4. Organization-scale and hosted

1. Durable hosted desired-state service and reconciliation loop.
2. Per-customer Terraform state, scoped credentials, fleet inventory, quota
   monitoring, and upgrade waves.
3. Isolated untrusted builders with egress/resource/time limits, build-secret
   separation, provenance, and log redaction.
4. Metering, cost ceilings, support/incident boundaries, and audited emergency
   access.
5. Regional failure strategy and explicit statement of whether recovery is
   restore-in-region, recreate-in-region, or fail over elsewhere.
6. Re-evaluate per-customer clusters against measured cost and operational load;
   introduce shared tenancy only with a separate threat model and isolation
   contract.

## Ticketing recommendation

Do not translate every finding above into a ticket. Create one decision record
for the production profile and one epic for its conformance suite. That decision
should close or re-scope several implementation tickets. Only then file the
small number of missing blockers that have no current owner: production
state/access bootstrap, platform data durability/restore, workload availability,
and incident-response closure.

The shortest path is:

```text
production profile
  -> reconciliation ownership decision
  -> immutable artifacts + remote state
  -> availability + data durability
  -> alert/restore/failure conformance
  -> first maturity-A workload
```

Everything else can wait until that workload has survived real operations.
