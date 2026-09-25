# AWS qualification Run 5, attempt 5 — 2026-09-19 (conformant through Ready)

> Moved verbatim on 2026-09-24 from `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md` (lines 729–855 at `a9d7d827`), when the HARDEN-002 epic was closed as a ticket and its run history moved into the qualification ledger. Headings keep their original levels; the text is unchanged. Index: `docs/qualification/README.md`.

## Run 5 attempt 5 (executed 2026-09-19) — CONFORMANT through Ready

**Result: the first conformant install of the run.** Authority: `main @ 852be182`,
verified before the run; the binary was built from that tree and its mtime did not
change during the attempt. Target `sol-qual9-86054342`, account `<qualification account>`
(the recorded precondition-1 deviation still applies).

```text
lifecycle phase: CloudBootstrap      [terraform-apply] ok (884.7s)
lifecycle phase: PlatformInstalling  platform-prerequisites-apply ok / platform-apply ok (171.7s)
provisioner-bootstrap-access-remove  ok (14.0s)
lifecycle phase: Ready               Done.
```

Then, with a real platform change (`alert_owner`):

```text
lifecycle phase: PlatformUpdating    platform-apply ok (80.5s) -> Ready
```

`PlatformInstalling` appeared **zero** times on the re-apply. The change landed
(`sol-qual9-oncall` present in `configmap/prometheus-server`), so this was a real
reconciliation and not a no-op apply.

### Rows qualified (convergence)

| row | evidence |
|---|---|
| I1–I2 | `CloudBootstrap` reported before any platform mutation; privileged installation authority held through chart RBAC |
| I3 | after de-escalation: `can-i get pods -n monitoring` **yes**, `create clusterroles` **yes**, `bind clusterroles` **no**, `escalate clusterroles` **no** — the corrected row semantics, confirmed live for the first time |
| I4 | RDS `available`, MultiAZ true, `DeletionProtection: true` while `Ready` |
| I5–I6 | `PlatformUpdating` (never `PlatformInstalling`), back to `Ready`, provisioner re-verified |
| I14 | `Ready` reached under the convergence contract with no `/proxy/` probe and no issuer condition |

Convergence by inspection, not just by the gate: 4 × `m6i.xlarge`, EKS `ACTIVE`,
server `v1.36.4-eks-4cc7921`, all platform workloads Ready (cert-manager 3×1/1,
ingress-nginx 1/1, argocd 7×1/1, redpanda 3×2/2, monitoring all Ready), PVCs
Bound (monitoring 3, redpanda 3).

### Read-only networking inspection (INFRA-036) — answered

The node security group admits a **different** group — the module's cluster
security group — on 443, 4443, 6443, 8443, 9443 **and 10250 (kubelet)**, from the
module's default `ingress_cluster_kubelet`/`ingress_cluster_https` rules. So:

- **control-plane → kubelet is contract**, and Sol depends on it: the Redpanda
  readiness check runs `kubectl exec … rpk cluster health` on every apply, which
  makes each apply a direct test of the path. It already exists — nothing changed.
- **arbitrary pod/service ports are not provided**, which is why the removed
  `/proxy/` probes could never pass. The disposition is now evidence, not
  inference.

Nothing about networking was modified in response to either observation.

### Rows qualified (behavioural — distinct from convergence)

| capability | evidence |
|---|---|
| log → Alloy → Loki → query | a broker topic created during the run (`sol-harden-9cd076`) appeared in Loki within 20 s, with `namespace`/`container`/`job=loki.source.kubernetes.pods` labels. Loki canary on the same target: `entries_total=929`, `missing_entries_total=0` |
| broker produce → consume | `rpk topic create -p 3 -r 3` OK; produce → `Produced to partition 0 at offset 0`; consume → read back; `rpk cluster health` → `Healthy: true`, nodes [0 1 2] |
| E5 — acknowledged-message loss on one broker loss | 200 messages produced with `acks=all`; 200 consumed before; broker pod deleted; **200 consumed after** → 0 loss |
| metric → Prometheus → query | `count(up)=10`, `count(up==1)=10`, `count(up==0)=0`, `count(kube_pod_info)=24` |
| E2 — Postgres failover RTO | forced Multi-AZ failover, `rebooting … 78 s … available`. **Method limitation: status-level, not connection-level** — no client was deployed, so the row is partly qualified |

### Findings

| # | finding | severity | owner |
|---|---|---|---|
| 21 | `sol cloud destroy` fails after the documented publish step: ECR repositories are not `force_delete`, so images published by the lifecycle block the teardown. Auditing the class found worse on both providers — loki/thanos buckets carried `prevent_destroy = true` (terraform refuses before attempting), so a durable-observability target could never be destroyed | high | **INFRA-037 — fixed and merged (`7e81dde5`)**, with ADR 0004, a structural guard and its mutation test |
| 22 | the Kafka-durability guarantee fires because *nothing in the scope* uses Kafka, not because a service needs something the profile cannot honour. `checkout_svc` is a stateless `/quote` service, so the fixture was right and the check was wrong | high | INFRA-038 (decision required on the predicate) |
| 23 | a long-running lifecycle operation cannot reacquire short-lived credentials: the SSO refresh token expired mid-run, the CLI still answered while terraform could not, and the teardown of a *billable* target could not authenticate | high | INFRA-039 |
| 24 | a behavioural observation nearly produced a confident false finding: `kubectl port-forward svc/loki` kept serving the instance replaced by the `PlatformUpdating` rollout (366 lines vs the pod's 36,523). The canary's independent metric is what caught it | medium | HARDEN-003 |
| 25 | cost-clean required an operator to delete the final snapshot by hand, so "destroyed and cost-clean" was not zero | medium | DEC-033 |

Finding 23's direction is the dangerous one and is why it is rated high: expiry
during provisioning wastes an attempt, expiry during **teardown** strands billable
infrastructure and disables the only supported path to remove it.

### Blocked / not executed (recorded as such, not claimed)

- **B1–B7, C1–C5, ingress request→response, Tempo traces, D3** — the deploy path.
  Scoping removed the TypeScript blocker and then finding 22 stopped the scoped
  deploy. The app lifecycle remains the largest unexplored area, which is why
  Attempt 6 should be application-centric.
- **G1–G3** — no alert receiver (recorded as blocked in the matrix).
- **E3/E4** — Postgres PITR and restore-into-clean-target; not attempted in this
  budget.
- **TLS issuance** — `base_domain` is `sol-qual5.invalid`, so no public issuer can
  validate; recorded as inconclusive rather than failed.

### Deviations (explicit, not silent)

1. **Teardown identity.** The documented `sol cloud destroy` could not
   authenticate with the `sol-qual` SSO profile (finding 23). The same documented
   command was re-run with `AWS_PROFILE=Administrator`, a static credential in the
   same account. Same command, same state, no manual infrastructure edits. Filed
   as finding 23 because the fallback saved the money but must not become the
   product answer.
2. **ECR repositories force-deleted** to let the documented destroy finish
   (finding 21). These were artifacts this run published, not infrastructure.
3. **The final RDS snapshot was deleted by hand** (finding 25 / DEC-033).
4. **A behaviour measurement was wrong before it was right** (finding 24), and the
   raw sequence is preserved: the empty query, the contradiction against the
   canary, and the stale-vs-actual metric comparison.

### Retention must be stated, not inferred (DEC-033)

A disposable qualification target sets `destroy_retention: none` in its target
file before teardown. The destroy then reports `retention: none ... no residual
billable artifacts` and passes no final-snapshot identity, so "cost-clean" is a
claim the run's own output supports rather than something an operator establishes
afterwards by deleting a snapshot by hand — which is what Attempt 5 needed.

Leaving the field absent is correct for a production target: retention stays
explicit (the destroy names the snapshot and how to remove it), and a
qualification run retaining nothing never changes what destroy promises by default.

### Cost-clean verification (independent)

EKS none · RDS instances 0 · RDS manual snapshots 0 · EC2 4 terminated · NAT
deleted · EIPs none · load balancers none · EBS volumes none · VPCs none · ECR
repositories none · CloudWatch log groups 0 · Route53 zones none · S3 tfstate 2
objects (the state itself, intentional).

Evidence bundle: `~/.sol/harden-run5-attempt5/` (apply, re-apply, deploy attempts,
all four destroy attempts, the network inspection and the consolidated record).
