---
id: AUDIT-076
type: audit-finding
severity: medium
source: production-readiness review 2026-09-16 (adversarial Sol-over-Kubernetes review)
---

Deployment-event history has no retention/pruning, unlike release records

## Program disposition

Deferred beyond maturity A. Roughly ten workloads and one team do not justify an
external audit-history system or make this a production-profile blocker. Promote
when deployment volume creates measurable ConfigMap growth or a cross-cluster
retention/compliance requirement appears.

**Depends on:** None.

**Description:** FEAT-072 gave release records bounded retention
(`--keep-releases N`, default 20, pruning old ConfigMaps after each
successful deploy while never pruning the current pointer or the release
it displaced). Deployment-event records (FEAT-070,
`Sol_cli_deployment_store`) got no equivalent — they are appended forever
as one immutable ConfigMap per deploy attempt with no pruning mechanism
at all, and no path to durability outside the cluster (a lost/rebuilt
cluster loses this history permanently, with nothing external to
reconstruct it from).

**Impact:** Low-stakes at maturity A (one team, one cluster, low deploy
frequency, low compliance bar). Becomes a real gap at B/C: unbounded
ConfigMap growth in a single namespace as deploy frequency and workload
count both grow, and — more importantly — "who deployed what when" being
entirely dependent on that one cluster's continued existence, with no
retained audit trail across a cluster rebuild or migration.

**Remediation (scoped to stopping unbounded growth — full external
durability/export is a larger initiative and explicitly out of scope
here):**

1. Add a `--keep-deployments N` retention step to `Sol_cli_deployment_store`,
   mirroring `Sol_cli_release_retention`'s existing pattern (ordered by
   `creationTimestamp`, prune beyond the last N per workspace/environment,
   never prune anything still referenced by a retained release record).
   Default N can be considerably higher than the release default (e.g.
   200) since deployment events are the finer-grained history.
2. Explicitly do NOT attempt external export/durability (e.g. to object
   storage or the observability backend) in this ticket — that's a
   separate, bigger design question (where to export, what format, who
   consumes it) worth its own ticket once a real need for cross-cluster-
   rebuild audit retention shows up; this ticket only stops the
   in-cluster unbounded-growth problem, which is cheap and uncontroversial
   today.

**Acceptance criteria:**

- Deployment-event ConfigMaps are pruned beyond a configurable retention
  count, same mechanism/tests shape as release retention.
- No currently-referenced record (e.g. the deployment behind the current
  release pointer) is ever pruned.

**Demo/example coverage:** Not applicable — internal history-retention
change, not an app-facing config surface.

**TypeScript-parity note (DEC-022):** No language-parity impact —
deploy-orchestration bookkeeping, independent of workload language.
