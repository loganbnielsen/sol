# Sol qualification status

**As of:** 2026-09-19 · **Code revision verified:** `main @ c642bb3e`
**Owner:** the independent audit function (`internal/pipeline/audits/`).
**Reconciled** 2026-09-19 after rebasing onto `origin/main` (PRs #362/#363/#364:
INFRA-042 fixed, GCP Attempt 4, HARDEN Run 7; #365/#366: entry-point docs and a
GCP inventory restructure, against which the findings' citations were re-anchored
to sections and rows).

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
| FND-0001 | GCP | Provisioner IAM role `roles/container.developer` grants Kubernetes API authority; the claimed RBAC-only boundary is not real | `INFRA-045` | `VERIFIED_DEFECT` | `OPEN` |
| FND-0004 | GCP | A partially-installed platform was not destructible through `sol cloud destroy` (CRD-backed state, CRDs absent) | `INFRA-042` (DONE) | `VERIFIED_DEFECT` | `FIXED_UNQUALIFIED` |
| FND-0008 | AWS (render) | Runtime Secret identity mismatch blocked the migration path | `INFRA-040` (READY: diagnostics only) | `VERIFIED_DEFECT` | `QUALIFIED` (Run 7) |

## Findings without tickets (and why)

| Finding | Classification | State | Why no ticket |
|---|---|---|---|
| FND-0002 | `DESIGN_GAP` | `OPEN` | The AWS provisioner can re-grant itself cluster-admin via `eks:AssociateAccessPolicy` — documented AWS behaviour; the unresolved part is Sol's intended steady-state authority contract, so the fix requires a design decision (narrow the role vs split identities), not a mechanical change |
| FND-0003 | `QUALIFICATION_GAP` | `OPEN` | Effective-authority and absence coverage are unexercised, not defective |
| FND-0005 | `QUALIFICATION_GAP` | `OPEN` | Service-networking ABANDON: observed twice (Attempts 3, 4) vs documented "blocks network deletion"; the decision (ABANDON vs `REMOVE_PEERING`) is a qualification gap, not a defect |
| FND-0006 | `QUALIFICATION_GAP` | `QUALIFIED` (Run 7) | Retention `none` reached provider-side `Absent` with nothing retained and no manual step |
| FND-0007 | `QUALIFICATION_GAP` | `BLOCKED` | GCP Cloud DNS solver gap + no delegated hostname; tracked in the GCP inventory and refused by name |
| FND-0009 | `OBSERVATION` | `OPEN` | Provider substrate/prereq differences; no defect |

## Current blockers recorded by the HARDEN epic (on `origin/main`, not audit findings)

These are owned by the AWS HARDEN agent (HARDEN-002) and are shown here only so
the frontier is legible; the audit ledger does not duplicate their evidence.

| Ticket | What | Effect on the frontier |
|---|---|---|
| `INFRA-043` | The deploy identity cannot get or create `sol-boundary-lease-<workspace>` | **The current AWS deploy blocker** — every `sol deploy` stops here, one grant short of a workload |
| `INFRA-044` | A failed migration printed the full Postgres URL, password included, into Sol's output and the Job's logs | Secret-exposure defect on the migration path |
| `INFRA-040` (residual) | `sol deploy` says "see the Job logs" *after* deleting them | Diagnostics/evidence-retention item; Run 7 demonstrated the live cost |
| Procedure gap | An RDS password with URI-reserved characters must be percent-encoded by the operator; `SOL_API_KEY` is absent from the deploy step | Run 7 deviation |

## One-line qualification frontier

| Provider | Furthest live state reached | Behaviourally conformant? |
|---|---|---|
| AWS | `CloudBootstrap → PlatformInstalling → Ready` (Run 7 attempt 7, third consecutive), application preflight PASS, **migration Job PASS (first time)**; deploy lease FAIL; workload NOT REACHED. Destroy completed to `Absent` with `retention: none` | **Platform install/update/ready + destroy: yes. Full profile: no** — application deploy blocked (`INFRA-043`), alerting blocked, several measured rows not run |
| GCP | `CloudBootstrap` conformant; `PlatformInstalling` ran as the declared provisioner for 424.2 s then stopped at `helm_release.cert_manager`'s post-install check (Attempt 4); destroy of a partially-installed platform completed through the documented lifecycle | **No** — platform never reached `Ready`; see FND-0001/0004/0007 |

---

## Invariant roll-up

Full realization and sources: `invariants/PROVIDER-NEUTRAL-INVARIANTS.md`.

| Invariant | AWS | GCP | Finding |
|---|---|---|---|
| AUTH-1 explicit target authority | QUALIFIED (behavioral, partial) | MECHANISM | — |
| AUTH-2 authn ≠ authz | HOLDS (static) | **DEFECT** | FND-0001 / INFRA-045 |
| AUTH-3 install authority only during transitions | QUALIFIED (behavioral) | QUALIFIED (behavioral, Attempt 4) | — |
| AUTH-4 revoke effective capability (no surviving path) | **DESIGN GAP** | **DEFECT** | FND-0002, FND-0001 |
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
| B deploy / pointer / rollback | **NOT RUN** | blocked by `INFRA-043` (deploy lease), formerly FND-0008 |
| C migration ordering | **PARTIAL PASS** | Run 7: `sol migrate apply` reached `Done.` and the deploy migration gate passed for the first time; ordering/rollback beyond the gate not run |
| D availability (drain, node loss, worker probes) | **NOT RUN** | blocked upstream of a running workload (`INFRA-043`) |
| E durability | E1 PASS; E5 PASS (0 loss); E2 partial (status-level RTO, no client); E3/E4 not run; E6/E7 not distinctly recorded | Run 5 Attempt 5 |
| F security posture | F1 mechanism; F5 partial (deploy deny/allow, corrected `can-i`); F2–F4 not run. Run 7 recorded a *refusal* of the deploy identity (a missing grant, `INFRA-043`, not a security pass) | Run 1 F5; Run 5 Attempt 5 I3 |
| G alerting | BLOCKED | no real receiver |
| H evidence-bundle integrity | Run 7 run record present; H6 absence check still has the EIP/NAT/EBS gap in `verify_aws_destroy` (Run 7's sweep was the harness's, not the verifier's) | Run 5/6/7 |
| I lifecycle phases | I1–I6 PASS (Run 5 Attempt 5); I10 PASS (Run 5 Attempt 1); Run 7 destroy under `destroy_retention: none` qualified live; I11/I12 unrun | Run 5/6/7 |
| J exclusions | Recorded | matrix |

## GCP campaign status (from the inventory)

| Stage | Status | Evidence |
|---|---|---|
| Bootstrap inventory | Complete (read-only) | `gcp-bootstrap-inventory.md` |
| Cloud substrate apply | QUALIFIED (behavioral) | Attempts 1–4 |
| Provisioner impersonation + install window | QUALIFIED (behavioral) | Attempt 4: platform stage ran as the declared provisioner 424.2 s; window revoked (8.1 s) |
| Platform install → Ready | **FAILED** | Attempt 4: `helm_release.cert_manager` post-install `startupapicheck` (cert-manager itself healthy) |
| Destroy from `Ready` | not reached | — |
| Destroy from partial install | FIXED_UNQUALIFIED, observed live | Attempt 4 completed the documented destroy; INFRA-042 (DONE) |
| Service-networking peering absence | QUALIFIED (behavioral, Attempts 3+4) | verified by provider API, not Terraform exit status |
| Cloud SQL deletion protection / prepare | MECHANISM (prepared and verified 21 s) | Attempt 2 |
| GCP query matrix / equivalent profile | **does not exist** | inventory remaining gap 7 |

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

## For the next AWS / GCP HARDEN run — the evidence it should collect

Prioritised, provider-tagged, and traceable to a finding/invariant:

1. **AWS (blocks the application half):** implement `INFRA-043` (the deploy
   lease grant), then run matrix B/D and record the observations with their
   identity (HARDEN-003). Confirm the `INFRA-040` diagnostics item and the
   `INFRA-044` redaction item.
2. **GCP (blocks everything):** a run whose platform install reaches `Ready`.
   The next live boundary is the `helm_release.cert_manager` post-install check;
   then the success-path `PlatformInstalling → Ready` revocation and the
   positive/negative provisioner probe (FND-0001, FND-0003, FND-0007).
3. **Both:** extend `verify_aws_destroy` to cover EIP/NAT/EBS so the absence row
   no longer rests on a manual sweep (FND-0003).
4. **GCP:** re-observe peering absence and decide ABANDON vs `REMOVE_PEERING`
   (FND-0005); and, if a test hostname is delegated, the TLS solver work
   (FND-0007).
5. **AWS:** decide FND-0002 and, if narrowed, prove the escalation path is
   denied or explicitly accepted.

## How to update this index

When a finding's **state** changes (classification rarely does), update the
finding's `State:` line and add a dated line recording the transition, then its
row here, then the matching invariant's qualification table. When a run is
executed, record the run identity (`provider`, `target`, `revision`, `profile`,
`timestamp`, cleanup deviations) in the run record and cite it here by that
identity. Do not promote `STATIC`/`MECHANISM` evidence to `BEHAVIORAL` to make a
row look green, and do not rewrite a finding's earlier conclusion to reflect a
later state.
