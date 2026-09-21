# Sol qualification status

**As of:** 2026-09-20 · **Code revision verified:** `main @ 9cd186c0`
**Owner:** the independent audit function (`internal/pipeline/audits/`).
**Reconciled** 2026-09-19 after rebasing onto `origin/main` (PRs #362/#363/#364:
INFRA-042 fixed, GCP Attempt 4, HARDEN Run 7; #365/#366: entry-point docs and a
GCP inventory restructure, against which the findings' citations were re-anchored
to sections and rows).
**Reconciled** 2026-09-20: #369 (FND-0010, item 5), then #370 and #376 landed plan
items 1, 2, 3, 4, 6 and 7 — FND-0001 and FND-0002 move to `FIXED_UNQUALIFIED`, and
the five tickets moved to `DONE` with their behavioural remainder named.

This is the compact answer to "what does Sol currently know?". It links to the
authoritative detail; it does not duplicate it. Detail lives in:

- invariants → `invariants/PROVIDER-NEUTRAL-INVARIANTS.md`
- findings → `findings/FND-*.md`
- reports → `2026-09-19_provider_contract_verification.md`
- source material → `research/`
- the executable contract → `docs/qualification/production-single-region-v1-matrix.md` (AWS)
- the GCP lifecycle proposal → `docs/qualification/gcp-bootstrap-inventory.md`

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

## Current blockers recorded by the HARDEN epic (on `origin/main`, not audit findings)

These are owned by the AWS HARDEN agent (HARDEN-002) and are shown here only so
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

Runs 1–7 are recorded in `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md`.
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
| 8 | T1 AWS app | Run 8: matrix B/C/D (deploy, rollback, availability) | `HARDEN-002` | 1 (**now clear**) | **yes** | **authorized 2026-09-20, blocked at operator preflight** (target absent, no AWS credentials, runtime inputs unset) — not run evidence; see `docs/qualification/2026-09-20-run8-aws.md` §"Preflight" | run record with its identity; B/C/D rows pass or are recorded |
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

Both runs complete `docs/qualification/run-record-template.md` (copied once per
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
