# Sol qualification status

**As of:** 2026-09-20 · **Code revision verified:** `main @ 9cd186c0`
**Owner:** the independent audit function (`internal/pipeline/audits/`).
**Reconciled** 2026-09-19 after rebasing onto `origin/main` (PRs #362/#363/#364:
INFRA-042 fixed, GCP Attempt 4, HARDEN Run 7; #365/#366: entry-point docs and a
GCP inventory restructure, against which the findings' citations were re-anchored
to sections and rows).
**Reconciled** 2026-09-24 (ledger restructure only — see the last section; the tables above
that section were not re-audited).
**Reconciled** 2026-09-20: #369 (FND-0010, item 5), then #370 and #376 landed plan
items 1, 2, 3, 4, 6 and 7 — FND-0001 and FND-0002 move to `FIXED_UNQUALIFIED`, and
the five tickets moved to `DONE` with their behavioural remainder named.

This is the compact answer to "what does Sol currently know?". It links to the
authoritative detail; it does not duplicate it. Detail lives in:

- invariants → `invariants/PROVIDER-NEUTRAL-INVARIANTS.md`
- findings → `findings/FND-*.md`
- reports → `2026-09-19_provider_contract_verification.md`
- source material → `research/`
- the executable contract → `internal/qualification/aws/production-single-region-v1-matrix.md` (AWS)
- the GCP lifecycle proposal → `internal/qualification/gcp/gcp-bootstrap-inventory.md`

Findings carry two orthogonal axes (see `README.md`): **Classification** (what it
is) and **State** (where it stands: `OPEN`, `FIXED_UNQUALIFIED`, `QUALIFIED`,
`BLOCKED`, `ACCEPTED`, `SUPERSEDED`). Evidence words are `STATIC` / `MECHANISM` /
`BEHAVIORAL`. "Unqualified" means "not yet established by evidence that could
have failed" — it never means "false".

---

## Findings (with their state)

| Finding | Provider | What | Ticket | Classification | State |
|---|---|---|---|---|---|
| FND-0001 | GCP | Provisioner IAM role `roles/container.developer` grants Kubernetes API authority; the claimed RBAC-only boundary is not real | `INFRA-045` | `VERIFIED_DEFECT` | `FIXED_UNQUALIFIED` (#376) |
| FND-0002 | AWS | The provisioner can re-grant itself cluster-admin via `eks:AssociateAccessPolicy` (documented AWS behaviour; the gap is Sol's authority contract) | `DEC-034` (decided) → `INFRA-046` | `DESIGN_GAP` | `FIXED_UNQUALIFIED` (#376) |
| FND-0004 | GCP | A partially-installed platform was not destructible through `sol cloud destroy` (CRD-backed state, CRDs absent) | `INFRA-042` (DONE) | `VERIFIED_DEFECT` | `FIXED_UNQUALIFIED` |
| FND-0008 | AWS (render) | Runtime Secret identity mismatch blocked the migration path | `INFRA-040` (DONE 2026-09-20) | `VERIFIED_DEFECT` | `QUALIFIED` (Run 7) |
| FND-0011 | AWS (live) | The deploy path `kubectl apply`s the Namespace; the deploy identity may only `create` it, so the apply step is Forbidden — on the first deploy and on the migration-gate recovery path alike | `INFRA-048` (fix merged #388) | `VERIFIED_DEFECT` | `QUALIFIED` — fixed and **live-retested** in Run 8 against the exact failing namespace (`annotations: {}`); the deploy's `[apply] ok` and no cluster-side change was needed |
| FND-0012 | AWS (preflight) | A target-level `omit` does not exempt a unit from the profile preflight, which makes whole-workspace deploy impossible while a workspace declares an unqualified language | `INFRA-049` | `VERIFIED_DEFECT` (remedy needs an intent decision) | `OPEN` |
| FND-0013 | AWS (live) | A direct deploy defaulted `--secret-backend` to the placeholder, defeating the destination's own `Customer_direct` → live, so the per-service Secret was emitted with **empty values** and the workload could not start — on the documented deploy command | `INFRA-050` (fix merged #390) | `VERIFIED_DEFECT` | `QUALIFIED` — fixed and live-retested: the documented command with no `--secret-backend` reconciled the same Secret in place (0 → 125/64 bytes) and the pod reached `1/1 Running` |
| FND-0014 | AWS (live) | The deploy identity could not maintain the release record, and the deploy reported success anyway: the pointer could not be patched, so it kept naming an older release while `sol rollback` and retention read it | `DEC-037` → `INFRA-054` (#394, record failure is fatal) + `INFRA-055` (#395, `get`+`replace`, no generic `patch`) · prune stays `OPEN` under `INFRA-051` | `VERIFIED_DEFECT` (severity **escalated**: fail-open) | `QUALIFIED` for the release-record invariant — live-retested: the pointer moved off the stale value it had held since the fail-open (`r-6d35ecdb…` → `r-291245be11e2b8a6`) |
| FND-0015 | guard/tooling | The account-artifact guard misses a bare 12-digit account id in prose; one tracked file already carries two | `INFRA-052` | `VERIFIED_DEFECT` | `OPEN` |
| FND-0016 | AWS (live) | A scoped deploy required its call graph to be inside the scope, so a unit that calls another unit could not be deployed alone — and with FND-0012 the workspace had **no route that deployed all its services** | `DEC-036` (option 4) → `INFRA-053` (merged #393) | `VERIFIED_DEFECT` | `QUALIFIED` — live-retested: `--scope payments/charge_svc` succeeded with `checkout_svc` deployed and unchanged, deploying exactly one service |
| FND-0017 | AWS (identities) | No identity the profile provides can follow Sol's own diagnostic instruction: `sol deploy` says to run `sol status`, but the deploy identity may not read `events` (the explanation), `cluster-access` may not read pods at all, the operator role has **no access entry**, and the diagnosis swallows a denied read into "no events" | `INFRA-056` (identity decision first, then the minimum read-only access; plus make the degradation visible) | `VERIFIED_DEFECT` | `OPEN` — the `notify-worker` workload itself stays `UNDETERMINED` |

## Findings without tickets (and why)

| Finding | Classification | State | Why no ticket |
|---|---|---|---|
| FND-0003 | `QUALIFICATION_GAP` | `OPEN` (absence half implemented in #376, still unexercised live) | Effective-authority and absence coverage were unexercised, not defective; `INFRA-047` now verifies EIP/NAT/EBS absence, and the effective-authority probe remains (item 9) |
| FND-0005 | `QUALIFICATION_GAP` | `ACCEPTED` (`DEC-035`, 2026-09-20) | Service-networking ABANDON: observed twice (Attempts 3, 4) vs the documented "blocks network deletion". Decided: keep `ABANDON` — network deletion plus the post-destroy network/peering query is the compensating mechanism, and `REMOVE_PEERING` would need a 5.x→8.x provider upgrade. The four invariants of that choice are in `DEC-035` |
| FND-0006 | `QUALIFICATION_GAP` | `QUALIFIED` (Run 7) | Retention `none` reached provider-side `Absent` with nothing retained and no manual step |
| FND-0007 | `QUALIFICATION_GAP` | `BLOCKED` | GCP Cloud DNS solver gap + no delegated hostname; tracked in the GCP inventory and refused by name, and the GCP matrix (#376) now carries it as a row a run must fail on |
| FND-0009 | `OBSERVATION` | `OPEN` | Provider substrate/prereq differences; no defect |
| FND-0010 | `QUALIFICATION_GAP` | `OPEN` | GCP `cert_manager` `startupapicheck` failure: analysed and narrowed to the API-server → webhook path, but the cause is not yet established (needs the Attempt 5 container log). A ticket follows **only if** Attempt 5 confirms reachability |
| FND-0024 | `VERIFIED_DEFECT` | `OPEN` | `kubectl probe` collapses "could not run" into `false`, so `sol logs`/`sol fn run` report an unreachable cluster as "not deployed"; `INFRA-063` |
| FND-0025 | `VERIFIED_DEFECT` | `OPEN` | A failed current-release-pointer read drops the previous release's prune protection, silently weakening `--keep-releases`' documented "never pruned"; `INFRA-064` |
| FND-0026 | `OBSERVATION` | `OPEN` | A missing *or unreadable* `migrations/` both mean "no migrations required" — the missing case is documented/test-pinned; the unreadable case is the residual | 
| FND-0027 | `OBSERVATION` | `OPEN` | Loki stream parse failures are dropped without a trace, so `sol logs` output is best-effort; no stated completeness invariant |

## Current blockers recorded by the HARDEN epic (on `origin/main`, not audit findings)

These were owned by the AWS HARDEN epic (HARDEN-002, closed as a ticket on 2026-09-24) and are shown here only so
the frontier is legible; the audit ledger does not duplicate their evidence.

| Ticket | What | Effect on the frontier |
|---|---|---|
| `INFRA-043`, `INFRA-044` (**cleared**) | Deploy-lease grant; migration-credential leak | Landed in #370 and #376. Their behavioural halves are Run 8's deploy step and the normal migration path; they no longer block the frontier |
| `INFRA-040` (**cleared**) | Deploy reported "see the Job logs" after deleting them | Closed 2026-09-20 as a Run 8 prerequisite: the failure is now read out of the Job before removal, and a failing Job is kept. See `DONE/INFRA-040.md` |
| Procedure gap | An RDS password with URI-reserved characters must be percent-encoded by the operator; `SOL_API_KEY` is absent from the deploy step | Run 7 deviation |

## One-line qualification frontier

| Provider | Furthest live state reached | Behaviourally conformant? |
|---|---|---|
| AWS | `CloudBootstrap → PlatformInstalling → Ready` (Run 7 attempt 7, third consecutive), application preflight PASS, **migration Job PASS (first time)**; deploy lease FAIL; workload NOT REACHED. Destroy completed to `Absent` with `retention: none` | **Platform install/update/ready + destroy: yes. Full profile: no** — the deploy lease now exists (#370), so the next AWS run exercises it; alerting blocked, several measured rows not run |
| GCP | `CloudBootstrap` conformant; `PlatformInstalling` ran as the declared provisioner for 424.2 s then stopped at `helm_release.cert_manager`'s post-install check (Attempt 4); destroy of a partially-installed platform completed through the documented lifecycle | **No** — platform never reached `Ready`; see FND-0001/0004/0007/0010 |

---

## Invariant roll-up

Full realization and sources: `invariants/PROVIDER-NEUTRAL-INVARIANTS.md`.

| Invariant | AWS | GCP | Finding |
|---|---|---|---|
| AUTH-1 explicit target authority | QUALIFIED (behavioral, partial) | MECHANISM | — |
| AUTH-2 authn ≠ authz | HOLDS (static) | **DEFECT** → fixed #376, unqualified | FND-0001 / INFRA-045 |
| AUTH-3 install authority only during transitions | QUALIFIED (behavioral) | QUALIFIED (behavioral, Attempt 4) | — |
| AUTH-4 revoke effective capability (no surviving path) | **DESIGN GAP** → implemented #376, unqualified | **DEFECT** → fixed #376, unqualified | FND-0002, FND-0001 |
| AUTH-5 steady-state identities bounded | QUALIFIED (partial) | GAP (publisher/deployer unimplemented; install identity exercised) | FND-0003 |
| DESTROY-1 every state → `Absent` | QUALIFIED (behavioral) | FIXED_UNQUALIFIED (Attempt 4) | FND-0004 / INFRA-042 |
| DESTROY-2 normal activity never blocks destroy | QUALIFIED (behavioral) | FIXED_UNQUALIFIED | FND-0004 |
| DESTROY-3 provider-owned graph | QUALIFIED (behavioral, AWS lifecycle) | MECHANISM | FND-0005 |
| DESTROY-4 terraform ≠ absence | QUALIFIED (behavioral; EIP/NAT/EBS gap) | QUALIFIED (behavioral, Attempts 3+4) | FND-0003, FND-0005 |
| DESTROY-5 emergency cleanup ≠ pass | OBSERVATION | OBSERVATION | — |
| RET-1 explicit retention; `none` = nothing retained | **QUALIFIED (behavioral, Run 7)** | BLOCKED (inexpressible) | FND-0006 |
| RET-2 protection/retention/preparation distinct | QUALIFIED | MECHANISM | FND-0003 |
| CRED-1 credentials per mutation, fail closed | QUALIFIED (behavioral) | MECHANISM | — |
| CRED-2 ambient state never selects authority | QUALIFIED (behavioral) | MECHANISM | — |
| PREREQ-1 host prerequisites fail before billable | OBSERVATION | MECHANISM | FND-0009 |
| IDENT-1 producer/consumer identity agreement | **QUALIFIED (behavioral, Run 7)** | not exercised | FND-0008 |
| EVID-1..4 evidence discipline | convention (partial) | convention (partial) | FND-0003 |
| SUBSTRATE-1 provider-realized substrate | QUALIFIED (behavioral) | MECHANISM | FND-0009 |
| SUBSTRATE-2 differences explicit | convention | convention | FND-0009 |

---

## Blocked qualification rows (need an external input, cannot be substituted)

| Row | Provider | Blocker |
|---|---|---|
| Alert delivery + acknowledgement (matrix G1–G3; DEC-026 §8) | AWS | A real production-profile receiver and an owner who can acknowledge. A local sink proves mechanism only. Blocked since Run 1. |
| GCP public TLS issuance | GCP | A delegated qualification hostname + a Cloud DNS (or external) solver (FND-0007). Cert-manager's own release also did not finish installing in Attempt 4. |

---

## AWS campaign status (from the matrix and HARDEN-002)

Runs 1–7 are recorded in `internal/qualification/` (one record per run; index in
`internal/qualification/README.md` — moved verbatim from the HARDEN-002 ticket on 2026-09-24).
**Runs 3 and 4's bundles are not in the tree and may not be cited as
qualification evidence** (they are defect-discovery history only).

| Matrix section | Status | Evidence |
|---|---|---|
| A target-capability preflight | PASS (behavioral) | Run 2 recorded A2/A4/A6/A10 negatives; A12 capacity enforced from Run 5 onward; Run 7 preflight PASS |
| B deploy / pointer / rollback | **NOT RUN** | was blocked by `INFRA-043` (deploy lease); the grant landed in #370, so Run 8 is the first attempt that can pass it |
| C migration ordering | **PARTIAL PASS** | Run 7: `sol migrate apply` reached `Done.` and the deploy migration gate passed for the first time; ordering/rollback beyond the gate not run |
| D availability (drain, node loss, worker probes) | **NOT RUN** | blocked upstream of a running workload; the `INFRA-043` lease grant (#370) removes the known blocker |
| E durability | E1 PASS; E5 PASS (0 loss); E2 partial (status-level RTO, no client); E3/E4 not run; E6/E7 not distinctly recorded | Run 5 Attempt 5 |
| F security posture | F1 mechanism; F5 partial (deploy deny/allow, corrected `can-i`); F2–F4 not run. Run 7 recorded a *refusal* of the deploy identity (a missing grant, `INFRA-043`, not a security pass) | Run 1 F5; Run 5 Attempt 5 I3 |
| G alerting | BLOCKED | no real receiver |
| H evidence-bundle integrity | Run 7 run record present; the H6 EIP/NAT/EBS absence gap in `verify_aws_destroy` is closed in #376 (the verifier now checks all three), awaiting a live residual assertion | Run 5/6/7 |
| I lifecycle phases | I1–I6 PASS (Run 5 Attempt 5); I10 PASS (Run 5 Attempt 1); Run 7 destroy under `destroy_retention: none` qualified live; I11/I12 unrun | Run 5/6/7 |
| J exclusions | Recorded | matrix |

## GCP campaign status (from the inventory)

| Stage | Status | Evidence |
|---|---|---|
| Bootstrap inventory | Complete (read-only) | `gcp-bootstrap-inventory.md` |
| Cloud substrate apply | QUALIFIED (behavioral) | Attempts 1–4 |
| Provisioner impersonation + install window | QUALIFIED (behavioral) | Attempt 4: platform stage ran as the declared provisioner 424.2 s; window revoked (8.1 s) |
| Platform install → Ready | **FAILED** | Attempt 4: `helm_release.cert_manager` post-install `startupapicheck` (cert-manager itself healthy); cause narrowed, not yet established — FND-0010 |
| Destroy from `Ready` | not reached | — |
| Destroy from partial install | FIXED_UNQUALIFIED, observed live | Attempt 4 completed the documented destroy; INFRA-042 (DONE) |
| Service-networking peering absence | QUALIFIED (behavioral, Attempts 3+4) | verified by provider API, not Terraform exit status |
| Cloud SQL deletion protection / prepare | MECHANISM (prepared and verified 21 s) | Attempt 2 |
| GCP query matrix / equivalent profile | **EXISTS, NOT RUN** | `gcp-production-single-region-v1-matrix.tsv`; verifier and mutation test make missing/failing/weak-evidence rows fail |

---

## Claims corrected by primary-source verification

The externally supplied packet is retained in `research/` unmodified. These
claims were corrected or discarded (detail in the report and findings):

| Packet claim | Verified result |
|---|---|
| `roles/container.developer` does not authorize Kubernetes workloads | **Refuted** (INFRA-045 / FND-0001) |
| Service Networking `deletion_policy = "ABANDON"` bypasses VPC deletion locks | **Corrected** — resource is `google_service_networking_connection`; ABANDON leaves the peering (FND-0005) |
| GKE 1.26+ plugin requirement cited to the auth page | **Citation corrected** to the cluster-access page |
| AWS VPC/ENI deletion contract cited to `aws_eks_cluster` | **Citation corrected** to VPC-delete + EKS network-requirements pages |
| `aws_rds_cluster` blocks destroy unless `skip_final_snapshot` | **Confirmed**, with the `final_snapshot_identifier` branch |
| Cloud SQL `deletion_protection` defaults protected | **Confirmed**, plus the API-level `settings.deletion_protection_enabled` |
| cert-manager CloudDNS solver exists; cert-manager Route53 uses IRSA | **Confirmed** |

---

## Sequenced plan (2026-09-19)

Owners are placeholders for assignment; work is owned by the assignee, while the
qualification lead (this function) sequences it, reviews the evidence and keeps
this board current. **Live runs are serialized — one target at a time, provider
by provider** — so each run's evidence carries one clean identity and one
operator. Code, docs and contract work proceed in parallel.

| # | Track | Work item | Ticket | Depends on | Live run | Status | Done when |
|---|---|---|---|---|---|---|---|
| 1 | T1 AWS app | Deploy-lease grant | `INFRA-043` | — | no | **LANDED #370** | `sol deploy` passes the lease step; an offline test pins the granted verbs against the issued ones |
| 2 | T2 authority | Split the provisioning / steady-state identities (decision ratified 2026-09-19) | `DEC-034` → `INFRA-046` | — | no | **LANDED #376**, `FIXED_UNQUALIFIED` (probe is item 9) | the steady-state identity holds no access-entry/`iam:*` permission; a guard pins it; ADR 0002 + matrix I3 revised |
| 3 | T2 authority | Narrow the GCP provisioner role | `INFRA-045` | — | no | **LANDED #376**, `FIXED_UNQUALIFIED` (probe is items 9/10) | a custom role limited to discovery/credential retrieval; the "no Kubernetes authority" claim corrected |
| 4 | T4 coverage | Redact the connection URL in migration errors | `INFRA-044` | — | no | **LANDED #376** | the password is absent from Sol's output and the Job logs, mutation-tested |
| 5 | T3 GCP platform | Root-cause the `helm_release.cert_manager` post-install failure | `HARDEN-004` / FND-0010 | 10 (the probe runs in that attempt) | **with #10** | prepared; probe defined in FND-0010 | the check's own container log is captured and the cause branch is settled (FND-0010's probe list) |
| 6 | T4 coverage | Absence verifier: EIP / NAT / EBS | `INFRA-047` | — | no | **LANDED #376**; live residual assertion outstanding | `verify_aws_destroy` covers all three, mutation-tested both directions |
| 7 | T4 contract | GCP matrix expressed against the provider-neutral invariants | `HARDEN-004` | — | no | **LANDED #376** (exists, not run) | rows exist for the invariants; the inventory becomes a contract a run can fail |
| 8 | T1 AWS app | Run 8: matrix B/C/D (deploy, rollback, availability) | `HARDEN-002` | 1 (**now clear**) | **yes** | **authorized 2026-09-20, blocked at operator preflight** (target absent, no AWS credentials, runtime inputs unset) — not run evidence; see `internal/qualification/records/2026-09-20-run8-aws.md` §"Preflight" | run record with its identity; B/C/D rows pass or are recorded |
| 9 | T2 authority | Steady-state authority probe | FND-0003 | 2, 3 (**both landed**) and a `Ready` target | **yes** | waiting on a `Ready` target | positives/negatives as the recorded identity, plus a denial in a non-`default` namespace |
| 10 | T3 GCP platform | Attempt 5 → `Ready`, then the success-path probe | `HARDEN-004` | 5 | **yes** | waiting on the run | phase lines, window open/close, readiness; then the FND-0001/0003/0007/FND-0010 probes |
| 11 | T2 contract | ABANDON vs `REMOVE_PEERING` | FND-0005 → `DEC-035` | — | no (decision) | **DECIDED 2026-09-20: keep `ABANDON`** | the four constraints are in `DEC-035`; revisit when `google >= 8.1` is itself qualified, or immediately if a run observes the documented failure |

Order of live runs — **decided 2026-09-20, not to be reordered**: **#8 (AWS
Run 8) first**; then **reconcile its evidence into the matrix, this ledger and the
findings before anything else**; only then **#10 (GCP Attempt 5)**. Never
concurrently. AWS goes first because it carries the larger qualification surface and
is the first attempt capable of reaching the application half, and because it
exercises the absence checks, the denied steady-state identity and the migration
gate in one run — so any common-path finding from it must be incorporated before a
GCP attempt is spent.

With item 11 decided, the remaining qualification frontier is **AWS Run 8 (#8,
which also carries item 9's probe) and GCP Attempt 5 (#10)**. Everything else on
this board is either landed or waiting on one of those two runs.

Both runs complete `internal/qualification/run-record-template.md` (copied once per
run), so the evidence arrives in the shape this board reads instead of being
reconstructed from terminal history afterwards.

Each work item starts with three things: an **owner**, its own **branch or
worktree**, and the **acceptance + evidence contract** — what must be observed,
as which identity, against which revision, and what would make it fail. A pass
without the third is not evidence.

## How to update this index

When a finding's **state** changes (classification rarely does), update the
finding's `State:` line and add a dated line recording the transition, then its
row here, then the matching invariant's qualification table. When a run is
executed, record the run identity (`provider`, `target`, `revision`, `profile`,
`timestamp`, cleanup deviations) in the run record and cite it here by that
identity. Do not promote `STATIC`/`MECHANISM` evidence to `BEHAVIORAL` to make a
row look green, and do not rewrite a finding's earlier conclusion to reflect a
later state.

## The operator identity and the status model (2026-09-21)

`DEC-038` is complete and verified live. `INFRA-057` (the identity), `INFRA-058`
(the grant follows the workload) and `INFRA-059` (the verdict is evidence-backed)
are all landed.

| | |
|---|---|
| Operator identity | real: access entry, read-only ClusterRole per workload namespace, `events`/`pods`/`pods/log`/`services`/`deployments`/`cronjobs`/`namespaces` — `get`/`list` only |
| Its bounds | verified live: no mutating verb, no `secrets`, no `pods/exec`, no `pods/portforward` |
| `FND-0017` | `QUALIFIED` — the operator obtained the diagnosis no identity could obtain, including the events |
| `FND-0018` | `QUALIFIED` — the grant is present in `pluto-checkout`, `pluto-payments` and `pluto-comms` after one `sol migrate apply`, with the workload untouched |
| `FND-0019` | `QUALIFIED` — `HEALTHY` can no longer be produced by a read that did not happen; the regression is mutation-verified |
| `notify-worker` | classified from the evidence: `DEGRADED`, readiness probe returns **HTTP 503** on one replica (0 restarts), the other `1/1` with 12 restarts |

**Run 8 frontier:** the diagnosability blocker is gone and the payment path works
(`FND-0016` qualified). §B is next, from **B3** — driving a representative
transaction. Note for the operator: B3 needs a port-forward to a ClusterIP service,
and no *workload* identity holds `pods/portforward` by design (DEC-038 §4 excludes it
from the operator, and the deploy identity is denied it), so B3 must be driven with
the qualification operator's `cluster-access` capability, and the run record must say
which identity served each read.

## Run 8 §B from B3 — attempted 2026-09-21: **BLOCKED**, and stopping

Two independent blockers, both now evidenced in the run record:

1. **No identity can transport into an application namespace.** `cluster-access` is
   cluster-admin in *platform* namespaces and has no access in application ones;
   `deploy`/`operator` are read-only there with no `portforward`/`exec`; the
   provisioner has no access entry; the SSO administrator is `Unauthorized` on the
   cluster. So the `-svc` half of B3 cannot be executed — a gap in the procedure's
   assumptions, not something to fix by widening DEC-038.
2. **The workload itself prevents an unambiguous result.** `notify-worker`'s consumer
   group joins and leaves — observed from the broker as `LAG 1` with **no members**,
   having been `Stable` with 2 members minutes earlier, which is the same instability
   its readiness probe (HTTP 503) shows, now from a second, independent source.

The two are coupled: only the application's own producer emits the schema-registry
framing the worker accepts, so producing a valid message *is* the `POST /charges` call
that blocker 1 prevents.

**Stop condition met, per the run's rule:** the degraded Deployment prevents B3 and
makes its result ambiguous, so the run stops rather than modifying the workload to
obtain a pass. `notify-worker` was not restarted, redeployed or reset — same pods, same
creation timestamps throughout.

**Awaiting an operator decision:** repair/reset the `notify-worker` fixture before using
subsequent evidence that depends on its consumer, or defer `§B`'s worker half. §D/§E
rows that depend on a healthy consumer are in the same position.

One procedural note that outlives this run: the evidence for "a message was processed"
came from the platform's own log store, and it **overturned** the broker's committed
offset, which read as success while the worker had skipped the record. Committed offset
is not evidence of processing.

## Run 8 frontier after the two harness decisions (2026-09-21)

Both decisions were taken as separate matters, and both hit a real limit -- each with
clean evidence rather than a workaround.

**Transport (DEC-039 / FND-0020 / INFRA-060).** The qualification-only capability was
built: `sol:qualifiers`, `pods`/`services` `get`/`list` and `pods/portforward` `create`,
nothing else, established outside `sol cloud apply`, with a guard (six mutations)
proving it cannot leak into production. But establishing it needed a temporary
privileged window -- no standing identity can write cluster-scoped RBAC, since the
installation authority was de-escalated (ADR 0003) -- and **closing that window did not
take effect**: the API reported `accessPolicies: null` while the authorizer still
granted cluster-admin, proven by reading an application's Secrets from a principal
confirmed at the time of the read. The credential was broader than its declared
contract, so it was **revoked rather than used** (`FND-0021` / `INFRA-061`, high
severity), with the general lesson that de-escalation must verify the effective
surface rather than the API's report -- including Sol's own `De-escalate` phase.

**Fixture reset (FND-0022 / INFRA-062).** Redeploying the recorded revision through the
documented mechanism succeeded and changed nothing: `generation` stayed 1, the same two
pods with the same creation timestamps, still 0/2 ready, still `DEGRADED`. An unchanged
deploy is idempotent **by design** -- B2 qualifies exactly that -- so "reset the
fixture" is not expressible and the procedure must say what it means. Stop condition
met: the run stopped rather than restarting the workload or reaching for
`kubectl delete pod`.

**Consequence.** B3 is still `NOT REACHED`, now for two documented reasons rather than
one unexplained one. §B4-§B7 and the consumer-dependent §D/§E rows are in the same
position. Also noted post-boundary: `sol deploy` cannot write `sol-deploy-state-pluto`
either (same `apply`->`patch` root cause as `INFRA-051`), so BUG-025's drift check has
no state to compare against.

## CI health note (2026-09-21): an unexplained red gate, recorded rather than explained away

`audit/fnd-0021-and-boundary` (#406) failed its `test` job **twice** (03:35 and 03:47) at
`FAIL: sol-deploy is no longer in the deploy bootstrap's bind allowlist` -- the guard's
own message, meaning its allowlist extraction came back empty.

What was ruled out, by inspection rather than assumption: the branch's
`platform_deploy_rbac.tf` contains the same allowlist as main and as two branches whose
`test` jobs passed; the guard carries the same extraction; it passes locally under dune
on that exact tree; and main was consistent, carrying both the allowlist and the
assertion that checks it.

The temporary instrumentation (#409, not for merge) made CI print what it actually sees,
and the answer is that **the failure no longer reproduces**: on the same content, with the
diagnostic in place, `test` **passed** (7m57s) and the guard's inputs were provably
correct --

```
cwd:                  .../_build/default/cli/sol/test
root argument:        ../../..            (relative)
rbac file:            ../../../cli/platform/infra/base/platform_deploy_rbac.tf
file exists:          yes
resource_names lines: 2
extracted allowlist:  both ClusterRoles, correctly
```

**Recorded as an unexplained failure plus a successful rerun, not as a diagnosis.** What
the diagnostic establishes: the guard's inputs are correct in CI. What it does not: why
those two runs saw otherwise. A plausible shape (a `_build` sandbox whose copy of the
Terraform file was absent or stale, making the extraction empty and producing exactly
that message) is *not* asserted, because the diagnostic did not run during a failure and
no cause was observed.

Worth keeping from this: instrument the thing that is inexplicably empty and ask the
runner, rather than reasoning from assumptions about it -- one CI cycle settled more than
an hour of local investigation had.

## Environment destroyed (2026-09-21)

The qualification target was destroyed through the documented path and verified
`Absent` (`EKS/RDS/ECR/load-balancers/EIPs/NAT-gateways/EBS-volumes not found`), exit 0.
Torn down deliberately rather than preserved: the next step was a CI diagnosis that needs
no AWS, and keeping a live target through a genuine pause invites exceptions.

The remaining sequence starts from a **fresh** target, which is itself evidence: several
fixes landed during this environment's lifetime, so rebuilding exercises them from clean
bootstrap rather than only against a repeatedly reconciled cluster.

**Open before that sequence:** the destroy path removes the bootstrap elevation but does
not verify the effective surface (DEC-040 applies to every revoking path) — a remaining
piece of INFRA-061, exposed by the teardown itself.

## Recovery-contract frontier (2026-09-24) — Attempt 7 stopped pre-live

`main @ 2775d5b1`. The tables above stop at FND-0027 and have not tracked the destroy-path
findings (FND-0030/FND-0044–0048/FND-0055–0056); this section brings the one frontier this
session touched current rather than reconstructing the whole index. Detail:
`HARDEN-004-handoff.md` (last section), `internal/qualification/records/2026-09-24-gcp-attempt7-prelive-falsification.md`.

The HARDEN-004 destroy-path programme landed its steps 2–5 between 2026-09-23 and 2026-09-24:
a typed destroy execution core with one state inventory, plan-and-assert on every destroy-path
apply, the wired failure policy with decided exit codes, and provider/retention verification taken
from observed evidence. **Verified**, from the code on `main` and those steps' own records:
destroy no longer performs an unasserted constructive apply; reconciliation is scoped to the
bootstrap mechanism plus the guarded addresses state represents; a preparation failure permits
destruction with the degradation reported; and retention is a typed observation rather than a
rendered policy string.

**What did not come with them is the ability to converge a *divergence*** — a target-declared
resource that the provider holds while Terraform state does not represent it (Attempt 6's shape).

| Finding | What | State |
|---|---|---|
| FND-0030 | Destroy unavailable for a partially-represented target | `OPEN` — mechanisms 1–2 landed; the convergence half (adoption) does not exist |
| FND-0044 / FND-0048 | Whole-root constructive applies; type-mapped address identities | fixed in steps 2–3 (`STATIC`/`MECHANISM`) |
| FND-0045 | Verification checked guessed names in a defaulted region | `FIXED_UNQUALIFIED` — remedy landed in step 5, with its orphan-sweep clause implemented narrower than written |
| FND-0046 | Retention printed from the policy | `FIXED_UNQUALIFIED` (INFRA-072); the query has never run live |
| FND-0055 | **New** — the verification's evidence set is the state inventory, so a divergent resource is invisible and its survival can be reported as "postcondition established" | `FIXED_UNQUALIFIED` — closed offline by the declared-universe unit (see below); one residual named |
| FND-0056 | **New** — the Attempt-7 property is not establishable by current `main`, and the attempt's criteria exclude the only mechanism the repository names for convergence | `OPEN` |
| DEC-044 | **New** — the ownership + coverage decision (options, recommendation, acceptance criteria) | **Decided 2026-09-24** — coverage B2 landed; recovery ownership A1 accepted *in principle only* |

**Attempt 7 was authorized, opened, and stopped before Phase 2** — no resource created, nothing
mutated, zero exposure re-verified from the provider. The required postcondition (divergent
resource `ABSENT`) is reachable only if the *provider* cascades the object's removal behind a
represented parent, which is provider behaviour, not this contract; that fixture was therefore
rejected rather than reported as a pass. Falsification, not qualification.

**The fail-open is closed (2026-09-24, offline).** `DEC-044`'s recommended first unit landed as
HARDEN-004 step 6 (the declared-universe unit), and FND-0055 moves to `FIXED_UNQUALIFIED`: the
verification's universe is now `declared ∪ state`, where the declared set comes from a read-only
non-destroy `plan -json` of the disposable root and state stays authoritative for what it
represents. For every declared address state does not represent, the provider is queried from
identity the plan itself establishes — PRESENT ⇒ violation, ABSENT ⇒ obligation satisfied,
attempted-UNKNOWN and unqueryable-identity ⇒ UNKNOWN ⇒ failure — and the operator output names
the address, the query and the consequence. The observation path is read-only: no apply, no
import, no state change, no widened Step-3 allowlist.

**Two things are still not true**, and neither is claimed. (a) The evidence is offline; the
recipes have still never run against a real provider, so `FIXED_UNQUALIFIED`, not `QUALIFIED`.
(b) One residual is named in FND-0055: with an *empty* pre-destroy state, a declared address whose
identity cannot be authoritatively built from configuration is recorded as a coverage limitation
rather than a failure — B2 cannot distinguish "never applied" from total state loss, and does not
pretend to. Positive or attempted evidence is never softened on that path.

**Frontier consequence:** the next live GCP attempt is still not the next *step* — `DEC-044`'s
recovery-ownership half is now the gate. Adoption is accepted **in principle** (A1: import into
Terraform ownership behind the existing saved-plan assertion, then the ordinary destroy), so the
smallest remaining decision is the A1 authority question: which per-kind identity is authoritative
enough to `terraform import` on, and what authorizes Sol to assume ownership of an object it did
not record. Until that is answered and implemented, a divergence fails loudly and names the
resource — which is the honest behaviour, not a pass. Adoption is **not** implemented, FND-0030
stays `OPEN`, and Attempt 7 stays closed.

## Ledger restructure and the lifecycle simplification plan (2026-09-24)

`main @ a9d7d827`. Bookkeeping, not a re-audit: nothing below was re-verified live.

- **The HARDEN epics are closed as tickets.** HARDEN-002 (AWS) and HARDEN-004 (GCP) were standing
  goals that could never finish, and read as actionable to `/work`. Their run history moved verbatim
  into `internal/qualification/` (index and operating rules: `internal/qualification/README.md`); the goals
  and acceptance criteria stay in the closed tickets and the matrices. The next live runs are their
  own authorization-gated tickets in `BACKLOG`: **HARDEN-007** (AWS Run 9, §B3 onward) and
  **HARDEN-006** (GCP Attempt 8, past cert-manager's `startupapicheck`, FND-0010).
- **The "Recovery-contract frontier" above is superseded as a plan.** Two investigations on
  2026-09-24 found that both observed provider/state divergences (Attempts 5 and 6) were
  operator-created, so the A1 authority question is no longer the gate. The authoritative plan is
  `2026-09-24_cloud_lifecycle_simplification_plan.md` (#491): **DEC-045** (Terraform destruction
  authority) gates every deletion, and **DOCS-022** carries the dated corrections to FND-0030,
  FND-0055, FND-0056 and DEC-044. **Corrected by DOCS-022 (2026-09-25):** each record, plus the
  Attempt 5/6 records and INV-DESTROY-1/4, now carries a dated correction note. A1 is withdrawn,
  and DEC-045 records Terraform's destruction authority with its four exception classes.
- **FND-0044** → `FIXED_UNQUALIFIED` (HARDEN-004 parts 2–3); **INFRA-068** and **INFRA-069** moved to
  `DONE`, having been implemented under the epic's name (parts 3 and 5) without the ticket-move guard
  firing.


## Attempt-8 harness preparation and four state corrections (2026-09-25)

`main @ 146eb90c`. This section brings the states the qualification re-baseline found stale up to
date and records what the GCP harness now does. It does not re-audit the tables above, and it is not
a live observation.

**Four transitions, each already determined by the existing record:**

| Finding | Was | Now | Determined by |
|---|---|---|---|
| FND-0029 | `OPEN` | `FIXED_UNQUALIFIED` | the fix merged as #445 and survived the provider-boundary refactor (`Sol_cli_gcp_cluster.platform_vars`, `Install`/`Destruction`); `INFRA-067` moved to `DONE` the same day |
| FND-0030 | `OPEN` | `FIXED_UNQUALIFIED` | its own closing condition — "*`OPEN` only until INFRA-076 removes the Sol-caused route*" — and INFRA-076 is `DONE`; the convergence half is withdrawn (DEC-045) |
| FND-0055 | `FIXED_UNQUALIFIED` | `SUPERSEDED` | REFAC-094 deleted B2, the unit this finding was closed against; DEC-045 restates the requirement and the coverage it wanted is a qualification duty |
| FND-0056 | `OPEN` | `SUPERSEDED` | the Attempt-7 property was withdrawn as a product requirement (DEC-045; A1 withdrawn) |

`INFRA-067` was fixed-but-still-`READY_FOR_ENGINEERING` (its fix merged in #445 while the ticket
stayed put — the state AGENTS.md names as the anti-pattern); it moved to `DONE` with its one
remaining acceptance item named as a qualification observation rather than work.

**Nothing above is `QUALIFIED`.** An implementation landing is not the same claim as reality
confirming it, so each transition is `FIXED_UNQUALIFIED` or `SUPERSEDED`.

**GCP Attempt 8, re-scoped — harness prepared, not launched.** The next live GCP run is no longer
"install, then probe": its purpose is to establish the *cause* of the cert-manager `startupapicheck`
failure (FND-0010) under the current implementation, with platform `Ready` as the alternate outcome.
The harness (`internal/qualification/gcp/live-qual.sh`) now:

- generates a target with **no** `cluster_issuer` — FND-0007 makes an issuer-declaring GCP target
  uninstallable and the install-time refusal is deliberate (a target that asks for TLS Sol cannot
  wire is refused, not half-built);
- captures the discriminator **immediately after a failed `sol cloud apply` and before any teardown**.
  `sol cloud apply` is the invocation that installs the platform; the old `platform` phase ran
  `sol deploy`, an *application* deploy, so it could never observe a platform-install failure at all;
- captures pre-teardown and post-teardown provider inventories with tri-state semantics
  (PRESENT / ABSENT / UNKNOWN, a failed read never read as absence) covering the classes
  INV-DESTROY-4 names — including Artifact Registry, the qualification-created service accounts, the
  custom role and its bindings. The harness's own network probe had used a guessed name
  (`<cluster>-vpc` where the root names it `<cluster>`), so it could only ever report a vacuous
  "absent" — FND-0045's class, in the harness;
- freezes both roots' Terraform state and copies Sol's run artifacts out of its 20-run pruning window
  (INFRA-075's lesson), indexed by `evidence-manifest.txt`;
- classifies the captured evidence (TLS_CA_OR_CERTIFICATE / CRD_OR_API_DISCOVERY / SCHEDULING /
  RBAC / WEBHOOK_REACHABILITY / UNKNOWN) with the matched lines quoted and **no default of
  "reachability"**.

Offline evidence: `internal/qualification/gcp/test-live-qual.sh` grew from 24 to 67 assertions, and
each new property was mutation-checked in both directions (moving the discriminator capture after the
teardown, dropping the state snapshot, dropping Sol's run evidence, collapsing UNKNOWN into ABSENT,
reading PRESENT as ABSENT, ignoring non-zero quota usage, and replacing the identity-based stop with a
pattern kill each fail the suite). **No live resource was created and no provider was mutated while
preparing it**; the read-only Phase-0 baseline of `sol-qualification` was re-taken — project ACTIVE,
billing enabled, no disposable resource, quota usage 0, durable bucket and delegated zone PRESENT and
resolving.

## Attempt 8 Phase 0 stopped pre-live (2026-09-25)

`main @ 1aad2623`. The authorized GCP Attempt 8 began and stopped in its **read-only Phase 0**: four
provider classes came back `UNKNOWN`, which is one of the run's stop conditions. **No provider was
mutated, nothing was created, no Terraform state was touched**, and the authorized
live-infrastructure attempt is **not** consumed by it.

Record: `internal/qualification/records/2026-09-25-gcp-attempt8-phase0-stop.md`. Ticket: **`INFRA-078`**.

Two harness defects, both found by running the merged harness against the real provider rather than by
reasoning about it:

| Defect | Evidence | Effect |
|---|---|---|
| `provider_probe` does not recognise the provider's own `NOT_FOUND` (underscore) form | the captured stderr in that stop's bundle (`inventory-service-account-provisioner.stderr`) | fail-closed `UNKNOWN` for four classes (the three service-account describes and the SA IAM policy), so the continuation gate is unreachable until it is fixed |
| `verify` sets `KEEP=1` *after* its failure branch, so the EXIT trap escalates to `destroy` | `destroy.log` in the same bundle | a failing `verify` can tear down the target it was asked merely to inspect; harmless in this execution only because no target file existed |

Nothing in this ledger advances because of it: no matrix row, no finding state, and `FND-0010` stays
`OPEN` — `NOT_REACHED`. Both fixes are harness-only and tracked by `INFRA-078`.

## GCP Attempt 8 (2026-09-25) — the FND-0010 cause, and a degraded teardown

`main @ dae9540d` (run record: `internal/qualification/records/2026-09-25-gcp-attempt8.md`; the pre-live stop
that preceded it: `internal/qualification/records/2026-09-25-gcp-attempt8-phase0-stop.md`). Live infrastructure
22:01:03Z → 22:26:22Z. **No billable residue**; durable prerequisites intact and the delegation
still resolving; `main`'s canonical checkout untouched throughout.

| Item | State after the run |
|---|---|
| `FND-0010` | cause **established**: `TLS_CA_OR_CERTIFICATE`. The check's own output is `x509: certificate signed by unknown authority`; the webhook Service had live endpoints (`10.1.0.78:10250`, `targetPort: https`) and the `ValidatingWebhookConfiguration` carried no injected `caBundle` at capture time. **The reachability hypothesis is falsified — no firewall rule is warranted.** Still `OPEN`: the fix is a separate authorization. |
| `FND-0058` (**new**) | `OPEN` — after a failed platform install, the supported destroy **skips the platform teardown** (reopening the window is a create, which the destroy's own scope refuses), leaving the platform state stale (11 resources) while the provider reality is gone. Ticket `INFRA-079` (decision required). |
| `INFRA-080` (**new**) | harness verdict refinements: the `impersonator-binding` class can never verify absence (the provider answers PERMISSION_DENIED for a deleted SA), `custom-role` must read GCP's `deleted: true` as absent, and `cloud_vars`' comment broke its own `printf` (harmless — Sol passes the var from the target). |
| `INV-AUTH-3` | failure-path window closure **OBSERVED** (`provisioner-bootstrap-access-remove` ok, 12.9 s); the success path still untested. |
| `INV-DESTROY-1` | failed-`PlatformInstalling` case exercised but **degraded** (`FND-0058`), so the row is not satisfied. |
| `INV-DESTROY-4` | cloud root queried class by class and absent (state serial 47, 0 resources); platform root not destroyed. |
| `INV-RET-1` | `destroy_retention: none` **OBSERVED live** on GCP (`-var=gcs_soft_delete_retention_seconds=0` in the applied plan). |
| `INV-SUBSTRATE-*`, `INV-IDENT-1` | `NOT REACHED` — the platform never installed. |

Nothing is `QUALIFIED` by this run: the discriminator is evidence about a cause, not a conformant
profile. Three harness defects found by the two executions (the Phase-0 stop and the run) were fixed
in #514/#516 before the attempt; the follow-ups above are recorded, not fixed.

## FND-0058 fixed offline — the authority matcher (2026-09-25)

The INFRA-079 decision unit found that the destroy defect Attempt 8 exposed was **not** a missing
lifecycle capability: REFAC-094 already recorded *"no CREATE/REPLACE except the bootstrap-authority
operation"* and `reconciliation_policy` implements it. The GCP authority declaration used `Exact`
(string equality) for a `count`-indexed resource whose plan address Terraform always writes as
`...[0]`, so the rule that permits the create could never match the plan that acquires it. AWS was
unaffected (its matcher is `Type`, instance-insensitive).

| Item | State after the fix |
|---|---|
| `FND-0058` | **`FIXED_UNQUALIFIED`** — fixed by `Sol_cli_terraform_plan.Resource` (this resource, any instance), declared for GCP. Offline evidence: 25 unit tests (5 new, mutation-controlled), the offline lifecycle suite asserting the destroy's phase order (acquire → platform teardown → release → substrate destroy) with the authority fixture now carrying `[0]`, and three mutations that each fail the suite — including the instance-blind matcher, which fails both the unit suite and the offline scenario. Live qualification is still required: a real target in failed `PlatformInstalling` destroyed by `sol cloud destroy` alone, both root states empty. |
| `DEC-048` | recorded — *destruction may construct authority, and only authority* |
| `FND-0059` / `INFRA-081` (**new**) | the same address-form class where eligibility and reporting are decided: AWS's guarded `aws_db_instance.postgres` is `count`-ed, so `preparations_eligible`'s string comparison never sees it (`STATIC`, `OPEN`) |
| `INFRA-082` (**new**) | the separate decision for state that is *already* stale when the substrate is absent (the preserved Attempt 8 platform state) |
| `INV-DESTROY-1` | still not satisfied; the offline half now passes, the live half is the qualification step |

Nothing here is `QUALIFIED`. The preserved Attempt 8 Terraform state, worktree and target were not
modified, and no cloud resource was touched.

## GCP FND-0058 qualified live (2026-09-26)

`main @ 67bdef8e`, fresh target `qual9/gcp/us-central1` (cluster `sol-qual-gcp-9`) — its own target key,
never Attempt 8's (`INFRA-084`), so the specimen was produced fresh and the preserved state was neither
inherited nor overwritten. Live 01:39:58Z → 02:06:44Z (26 m 46 s); zero billable residue; durable
prerequisites intact; delegation resolving.

| Item | State after the run |
|---|---|
| `FND-0058` | **`QUALIFIED`** — a target in failed `PlatformInstalling` was destroyed by `sol cloud destroy` alone: the instance-qualified authority `CREATE` was permitted and applied (`Resources: 1 added, 0 changed, 0 destroyed`), the platform teardown ran (`platform-destroy ok, 77.2 s`, where Attempt 8 skipped it), the authority was removed, the substrate was destroyed, and **both roots ended empty** (cloud 0/16, platform 0/5). Record: `internal/qualification/records/2026-09-26-gcp-fnd0058-live-qualification.md` |
| `INV-DESTROY-1` | the **failed-`PlatformInstalling` case is satisfied**; `CloudBootstrap`, `Ready` and interrupted-destruction cases remain unobserved |
| `INV-DESTROY-4` | the failed-install case now ends with both roots empty plus an independent class-by-class sweep; the `Ready` case is not observed |
| `INV-AUTH-3` | window closure on the install-failure path observed again (10.6 s, before the failure was reported) |
| `FND-0010` | unchanged and `OPEN` — reproduced as `TLS_CA_OR_CERTIFICATE`, used only as the cheapest way to produce the specimen; no remediation attempted |
| `FND-0059` / `INFRA-081`, `INFRA-082`, `INFRA-083` | unchanged; `INFRA-080` gained the live corroboration of all three verdict refinements |
| Attempt 8 evidence | untouched: platform state 11 resources / serial 4, worktree, target and bundle as they were |

Nothing about `Ready`-state destruction is claimed: the destroy began from a failed install, not from a
healthy platform.

## INFRA-080 fixed — a clean teardown can now verify truthfully (2026-09-26)

Attempts 8 and 9 both ended with "teardown NOT verified" for reasons that were the *instrument's*,
not the product's: a provider-deleted service account whose `describe` answers
`PERMISSION_DENIED … (or it may not exist)`, the impersonator binding on that identity, and GCP's
soft-deleted custom role (`deleted: true`). All three — plus the `cloud_vars` comment that ended its
own `printf` — are fixed in `internal/qualification/gcp/`.

| class | postcondition | observable now |
|---|---|---|
| `service-account-provisioner` | the identity is not active | the project's authoritative active-account **list** (the ambiguous `describe` is kept as raw evidence) |
| `impersonator-binding` | no **usable** impersonation authority | the identity's active state (a deleted identity cannot be impersonated), plus the impersonator's bindings on the policy when the identity is active |
| `custom-role` | no **active** role of that name | `describe` with GCP's own `deleted` marker: `deleted: true` → ABSENT, the raw marker preserved |
| `cloud_vars` | the harness passes no unparseable argument | the target is the single source for `provisioner_impersonator` |

Nothing was relabelled: `PERMISSION_DENIED` is still never absence, and a failed authoritative read
is still UNKNOWN. The offline suite is **117 assertions (was 90)**, with five mutations proving the
tests protect the epistemic rule rather than the desired word. No product code, no live
infrastructure, and the preserved Attempt 8 state is untouched.

## FND-0010 fixed -- the platform apply stopped cutting cert-manager's readiness check short (2026-09-26)

`VERIFIED_DEFECT` -> `FIXED_UNQUALIFIED`. Attempt 9's product log ended the platform
prerequisites apply with `failed post-install: ... timed out waiting for the condition`; the
chart's post-install hook Job was created at 01:52:46Z and the apply failed at ~01:57:41Z --
300 s later, the Helm provider's default `timeout`, which bounds that hook's wait as well as
the main install. The check itself was still polling (`x509: certificate signed by unknown
authority`, no injected `caBundle`, webhook configuration at `generation: 1`) while all three
cert-manager Deployments had been `1/1 Running` for 6m39s. The API-server -> webhook
*reachability* branch the finding opened with is **refuted** (an x509 from the API server
proves the connection succeeded); no firewall rule is warranted.

The shared platform module now gives the check its designed budget (10m per attempt, 1 retry),
states `wait = true`, and sets an explicit 30-minute release `timeout` so Terraform cannot cut
it short again; the check stays **enabled**, because it is the only signal that the webhook is
usable. Pinned by `internal/ci/check_cert_manager_readiness.sh` plus a mutation self-test whose
first case is the pre-fix configuration, and by the offline lifecycle suite's assertion that a
failed cert-manager gate never runs the full platform apply. The qualifier's discriminator now
also captures the CA/TLS Secrets and the cert-manager component logs, so a further failure can
be attributed rather than re-run.

**`HARDEN-008`** (new, `BACKLOG`, authorization-gated) is the confirmation run: one fresh GCP
attempt whose purpose is to see cert-manager's check pass and the install continue -- to
`Ready` if the rest of the platform installs.

## Attempt 10 — post-FND-0010 GCP run (2026-09-26, `main @ bc9062b0`)

Full record: `internal/qualification/records/2026-09-26-gcp-attempt10-fnd0010-live.md`
(bundle `/tmp/sol-gcp-qual-10`, 286 files). Fresh target `qual10/gcp/us-central1`, cluster
`sol-qual-gcp-10`, its own state key; Attempt 8's preserved state and the `qual9/…` key untouched.

**Outcome: the platform did not reach `Ready`; the supported destruction path ran clean.**

| Boundary | Result |
|---|---|
| Cloud infrastructure (CloudBootstrap) | created — GKE `RUNNING`, Cloud SQL `RUNNABLE` |
| Platform install | **failed** at cert-manager's post-install check, `BackoffLimitExceeded` |
| FND-0010's pre-fix signature (`x509` / unknown authority) | **absent** — not reproduced |
| `PlatformInstalling → Ready` | **not reached** |
| Temporary authority (acquire → teardown → release) | observed exactly; `platform-destroy ok (77.3s)`, no degraded preparation |
| Failed-`PlatformInstalling` destruction (INV-DESTROY-1) | reproduced on a second revision; both roots empty (cloud 0, platform 0) |
| Independent provider verification | `teardown verified: absent` — 19 disposable classes ABSENT, quota 0, 2 durable PRESENT, delegation resolving |
| `Ready`-state destruction (INV-DESTROY-1's `Ready` case) | **not observed** |

**CORRECTION (2026-09-26, forensic re-analysis of the same bundle).** The first version of this
section attributed the failure to a container-start delay (`FND-0060`, `INFRA-087`). That reading is
refuted by the bundle's authoritative fields: the check ran its full `check api --wait=10m` window
(122 webhook TLS handshake failures every ~5s, 15:17:28 to 15:27:29 = 601s; Job `startTime`
15:16:59Z, `failed: 1`, `backoffLimit: 1`, pod `restartPolicy: OnFailure`, `activeDeadlineSeconds`
unset; exactly one pod created). The established cause is that cert-manager's controller and
cainjector **never acquired leader election**: the chart's default
`global.leaderElection.namespace` is `kube-system`, which GKE Autopilot denies (GKE Warden
managed-namespaces-limitation, 30 denials each across the whole window), so cainjector never
injected the webhook's `caBundle` (the field is absent) and the check's TLS polls could never
succeed. `FND-0060` is `FALSIFIED`, `INFRA-087` is withdrawn, the defect is `FND-0010` (state
`OPEN` — its budget remedy validated live here but insufficient), and the fix is proposed in
`INFRA-088`. No live mutation without separate authorization.

**Nothing here is QUALIFIED.** `Ready` was not reached; the failed-`PlatformInstalling` destruction
case and the authority bracket were reproduced, neither of which is new. Two instrument observations are recorded in the run record and
are not fixed here: `verify` aborts on an unset `IMPERSONATOR`, and the classifier can attribute a
cause from long-resolved events.

FND-0010 stays `FIXED_UNQUALIFIED`: its remedy was exercised (the release waited instead of
aborting) but the confirming observations — check Succeeded, install continuing, `Ready` — did
not occur.

## FND-0060 fix landed — offline only (2026-09-26)

`INFRA-088` landed the fix for the cause Attempt 10's re-analysis established:
`global.leaderElection.namespace` in `helm_release.cert_manager` now references the cert-manager
namespace resource instead of inheriting the chart's `kube-system` default, and
`check_cert_manager_readiness.sh` refuses omission, `kube-system`, another namespace, a literal, a
wrong reference, and a renamed namespace (six new mutations; fourteen in total, all rejected).

**Nothing here is QUALIFIED.** `FND-0060` is `FIXED_UNQUALIFIED`: the change is platform
configuration verified statically and offline, which says nothing about what a cluster does.
`FND-0010` stays `FIXED_UNQUALIFIED` on its own narrower claim (its budget remedy is live-validated
— the check received its full 600s window in Attempt 10 — but successful readiness and TLS trust
are not demonstrated).

The next authorized live run is a **fresh qualification target** and should discriminate the whole
chain in one specimen: cert-manager installs → leader election in `cert-manager` (no `kube-system`
Warden denial) → controller and cainjector acquire leadership → `caBundle` populated → check Job
Succeeds → Helm release succeeds → the platform install continues. On success the run continues
toward `Ready` and Ready-state destruction rather than stopping at cert-manager; if another
component becomes the first blocker, its evidence is preserved and it is classified rather than
repaired in-run.

## Attempt 11 — cert-manager qualified live; next blocker exposed (2026-09-26, `main @ 17afc4b2`)

Full record: `internal/qualification/records/2026-09-26-gcp-attempt11-cert-manager-qualified-new-blocker.md`
(bundle `/tmp/sol-gcp-qual-11`). Fresh target `qual11/gcp/us-central1`, cluster `sol-qual-gcp-11`.

| Boundary | Result |
|---|---|
| CloudBootstrap / CloudReady | created — GKE `RUNNING`, Cloud SQL `RUNNABLE` (`terraform-apply ok 549.6s`) |
| Platform install | **failed at `platform-apply`** (201.6s) after `platform-prerequisites-apply ok` (143.7s) |
| `FND-0060` (leader election / caBundle / check) | **QUALIFIED live** — all six transitions observed in the positive direction |
| `FND-0010` (readiness budget) | **QUALIFIED live** on its narrow claim — the check completed inside the budget (release complete in 2m13s) |
| `PlatformInstalling → Ready` | **not reached** |
| Ready-state destruction (`INV-DESTROY-1`/`-4` Ready cases) | **not observed** |
| Failed-install destruction + authority bracket | reproduced: acquisition → `platform-destroy ok (129.1s)` → release → substrate `terraform-destroy ok (345.2s)`; both roots empty (cloud 0/serial 16, platform 0/serial 12) |
| Independent verification | `teardown verified: absent`; durable bucket + zone PRESENT; delegation resolving; no billable residue |
| Manual/emergency action | none |

**New frontier:** `FND-0061` / `INFRA-089` (BACKLOG, decision required) — two `kubernetes_role_binding`
resources in `platform_provisioner_rbac.tf` write the same Kubernetes name
(`sol-platform-provisioner`), so the targeted prerequisites step creates the object and the full
apply cannot. Deterministic for a fresh GCP target and previously masked by the cert-manager
failure. No fix attempted during the run.

## FND-0061 fix landed — offline only (2026-09-26, `INFRA-089`)

The RoleBinding duplication that failed Attempt 11's full platform apply is fixed by giving the one
Kubernetes object one Terraform owner: both pairs (`platform_provisioner` and
`platform_provisioner_cluster`) now carry the group subject and the GCP provisioner subject, the
duplicate `_gcp` resources and the two AWS `moved` blocks naming them are deleted, and
`check_kubernetes_object_ownership.sh` enforces the invariant with nine mutation-tested cases.

**Nothing here is QUALIFIED.** `FND-0061` is `FIXED_UNQUALIFIED`: static and offline only.

Also corrected in the same unit, because it misled Attempt 11's own record: the qualification
classifier now prefers the failed operation's own error (a Terraform `already exists` → 
`TERRAFORM_ALREADY_EXISTS`) over ambient cluster evidence, and labels the ambient scheduling
fallback `SCHEDULING_AMBIENT` rather than `SCHEDULING`.

The next authorized live run is a fresh target whose discriminator is: prerequisites apply and full
`platform-apply` both complete; each platform namespace's RoleBinding and the ClusterRoleBinding
carry both subjects with one owner; and the install continues past this point toward `Ready` and
Ready-state destruction.

## Attempt 12 — FND-0061 qualified live; the next blocker is an environment quota (2026-09-26, `main @ cf43aaee`)

Full record: `internal/qualification/records/2026-09-26-gcp-attempt12-fnd0061-qualified-ssd-quota-blocker.md`
(bundle `/tmp/sol-gcp-qual-12`). Fresh target `qual12/gcp/us-central1`, cluster `sol-qual-gcp-12`.

| Boundary | Result |
|---|---|
| CloudBootstrap / CloudReady | created — `terraform-apply ok (510.9s)` |
| Platform prerequisites | **ok (124.2s)** — cert-manager, provisioner RBAC; no collision |
| Full `platform-apply` | **failed (1342.1s)** — Terraform `context deadline exceeded`, i.e. Helm releases waiting on unprovidable volumes |
| `FND-0061` (one object, one owner) | **QUALIFIED live** — the former collision boundary was crossed, no `already exists` |
| `FND-0060` / `FND-0010` | remain QUALIFIED (cert-manager installed again on this fresh target) |
| `PlatformInstalling → Ready` | **not reached** — blocked by `FND-0062` |
| Ready-state destruction (`INV-DESTROY-1`/`-4` Ready cases) | **not observed** |
| Failed-install destruction + authority bracket | reproduced: `platform-destroy ok (135.4s)`, substrate `346.6s`; both roots empty (cloud 0/serial 16, platform 0/serial 12) |
| Independent verification | `teardown verified: absent`; durable bucket + zone PRESENT; delegation resolving; no billable residue; `SSD_TOTAL_GB` usage back to 0 |
| Manual/emergency action | none |

**New frontier:** `FND-0062` / `INFRA-090` (BACKLOG) — the observability stack's PVCs cannot be
provisioned because the project's `SSD_TOTAL_GB` quota (500 GiB) is fully consumed by the Autopilot
nodes' own 100 GiB boot disks, while the platform asks for 20 GiB. Environment precondition, not a
lifecycle defect; the harness preflight missed it because it reads no disk quota.

## INFRA-090 landed — disk-quota precondition, offline only (2026-09-26)

`FND-0062` is `FIXED_UNQUALIFIED`. The lifecycle observes the provider's regional `SSD_TOTAL_GB`
after the cloud infrastructure exists and before the platform asks for a volume, compares it with
`Sol_cli_platform_storage.minimum_gb` (20 GiB, from the platform's own declarations), refuses with
the numbers when it does not fit, and fails closed on an unreadable read. The provider's node
behaviour is not modelled — the observation carries whatever footprint the cluster has already made.

**Qualification project state: `SSD_TOTAL_GB` raised 500 → 1000 GiB and confirmed effective**
(`gcloud compute regions describe us-central1` reports `limit=1000.0`). Nothing else about the
project changed; both durable prerequisites remain, both Terraform roots are empty of target state.

The next authorized live run is a fresh target whose discriminator is: the quota check passes with
the numbers printed, the observability PVCs bind, loki and the monitoring stack become ready, and the
install continues toward `Ready` and Ready-state destruction. The run also captures the provisioner
bindings on success, closing FND-0061's last inference.
