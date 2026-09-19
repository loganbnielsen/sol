# Sol qualification status

**As of:** 2026-09-19 · **Code revision verified:** `main @ 7ea2ef43`
**Owner:** the independent audit function (`internal/pipeline/audits/`).

This is the compact answer to "what does Sol currently know?". It links to the
authoritative detail; it does not duplicate it. Detail lives in:

- invariants → `invariants/PROVIDER-NEUTRAL-INVARIANTS.md`
- findings → `findings/FND-*.md`
- reports → `2026-09-19_provider_contract_verification.md`
- source material → `research/`
- the executable contract → `docs/qualification/production-single-region-v1-matrix.md` (AWS)
- the GCP lifecycle proposal → `docs/qualification/gcp-bootstrap-inventory.md`

Status words are the shared set in `README.md`; evidence words are
`STATIC` / `MECHANISM` / `BEHAVIORAL`. "Unqualified" means "not yet established
by evidence that could have failed" — it never means "false".

---

## Open defects (with tickets)

| Finding | Provider | Defect | Ticket | Ticket state |
|---|---|---|---|---|
| FND-0001 | GCP | Provisioner IAM role `roles/container.developer` grants Kubernetes API authority; the claimed RBAC-only boundary is not real | `INFRA-043` | READY |
| FND-0004 | GCP | A partially-installed platform is not destructible through `sol cloud destroy` (CRD-backed state, CRDs absent) | `INFRA-042` | READY |
| FND-0008 | AWS (render) | Runtime Secret identity mismatch (`sol-secrets` vs `sol-secrets-secrets`) blocks every cloud deploy | `INFRA-040` | READY |

## Open findings without tickets (and why)

| Finding | Status | Why no ticket |
|---|---|---|
| FND-0002 | `DOCUMENTATION_GAP` | The AWS provisioner can re-grant itself cluster-admin via `eks:AssociateAccessPolicy`; the fix requires a decision (narrow the role vs split identities), not a mechanical change |
| FND-0003 | `QUALIFICATION_GAP` | Effective-authority and absence coverage are unexercised, not defective |
| FND-0005 | `QUALIFICATION_GAP` | Service-networking ABANDON: observed once vs documented "blocks network deletion"; GCP agent owns re-observation |
| FND-0006 | `QUALIFICATION_GAP` | Retention code/harness fixed; live `Absent` postcondition unproven |
| FND-0007 | `QUALIFICATION_GAP` | GCP cert-manager Cloud DNS gap already tracked in the GCP inventory; product fails closed |
| FND-0009 | `OBSERVATION` | Provider substrate/prereq differences; no defect |

## One-line qualification frontier

| Provider | Furthest live state reached | Behaviourally conformant? |
|---|---|---|
| AWS | `CloudBootstrap → PlatformInstalling → Ready → PlatformUpdating → Ready` (Run 5 Attempt 5, Run 6 Attempt 6); destroy completed (Run 6) | **Platform install/update/ready + destroy: yes. Full profile: no** — application deploy blocked (FND-0008), alerting blocked, several measured rows not run |
| GCP | `CloudBootstrap` conformant; `PlatformInstalling` failed (missing host plugin); destroy from partial install fails | **No** — platform never reached `Ready`; see FND-0001/0004/0007 |

---

## Invariant roll-up

Full realization and sources: `invariants/PROVIDER-NEUTRAL-INVARIANTS.md`.

| Invariant | AWS | GCP | Finding |
|---|---|---|---|
| AUTH-1 explicit target authority | QUALIFIED (behavioral, partial) | MECHANISM | — |
| AUTH-2 authn ≠ authz | HOLDS (static) | **DEFECT** | FND-0001 / INFRA-043 |
| AUTH-3 install authority only during transitions | QUALIFIED (behavioral) | MECHANISM | — |
| AUTH-4 revoke effective capability (no surviving path) | **GAP** | **DEFECT** | FND-0002, FND-0001 |
| AUTH-5 steady-state identities bounded | QUALIFIED (partial) | GAP (publisher/deployer contract unimplemented) | FND-0003 |
| DESTROY-1 every state → `Absent` | QUALIFIED (behavioral) | **DEFECT** | FND-0004 / INFRA-042 |
| DESTROY-2 normal activity never blocks destroy | QUALIFIED (behavioral) | MECHANISM | — |
| DESTROY-3 provider-owned graph | QUALIFIED (behavioral, AWS lifecycle) | MECHANISM | FND-0005 |
| DESTROY-4 terraform ≠ absence | QUALIFIED (behavioral; EIP/NAT/EBS gap) | QUALIFIED (behavioral, once) | FND-0003, FND-0005 |
| DESTROY-5 emergency cleanup ≠ pass | OBSERVATION | OBSERVATION | — |
| RET-1 explicit retention; `none` = nothing retained | MECHANISM (**behavioral gap**) | BLOCKED (inexpressible) | FND-0006 |
| RET-2 protection/retention/preparation distinct | QUALIFIED | MECHANISM | FND-0003 |
| CRED-1 credentials per mutation, fail closed | QUALIFIED (behavioral) | MECHANISM | — |
| CRED-2 ambient state never selects authority | QUALIFIED (behavioral) | MECHANISM | — |
| PREREQ-1 host prerequisites fail before billable | OBSERVATION | MECHANISM | FND-0009 |
| IDENT-1 producer/consumer identity agreement | **DEFECT** | not exercised | FND-0008 / INFRA-040 |
| EVID-1..4 evidence discipline | convention (partial) | convention (partial) | FND-0003 |
| SUBSTRATE-1 provider-realized substrate | QUALIFIED (behavioral) | MECHANISM | FND-0009 |
| SUBSTRATE-2 differences explicit | convention | convention | FND-0009 |

---

## Blocked qualification rows (need an external input, cannot be substituted)

| Row | Provider | Blocker |
|---|---|---|
| Alert delivery + acknowledgement (matrix G1–G3; DEC-026 §8) | AWS | A real production-profile receiver and an owner who can acknowledge. A local sink proves mechanism only. Blocked since Run 1. |
| GCP public TLS issuance | GCP | A delegated qualification hostname + a Cloud DNS (or external) solver (FND-0007) |
| Retention `none` live `Absent` | AWS | None external — needs a run that declares `destroy_retention: none` and observes `Absent` (FND-0006) |

---

## AWS campaign status (from the matrix and HARDEN-002)

Runs 1–6 are recorded in `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md`.
**Runs 3 and 4's bundles are not in the tree and may not be cited as
qualification evidence** (they are defect-discovery history only).

| Matrix section | Status | Evidence |
|---|---|---|
| A target-capability preflight | PASS (behavioral) | Run 2 recorded A2/A4/A6/A10 negatives; A12 capacity enforced from Run 5 onward |
| B deploy / pointer / rollback | **NOT RUN** | blocked by FND-0008 (INFRA-040) |
| C migration ordering | **NOT RUN** | blocked by FND-0008 |
| D availability (drain, node loss, worker probes) | **NOT RUN** | blocked by FND-0008 |
| E durability | E1 PASS; E5 PASS (0 loss); E2 partial (status-level RTO, no client); E3/E4 not run; E6/E7 not distinctly recorded | Run 5 Attempt 5 |
| F security posture | F1 mechanism; F5 partial (deploy deny/allow, corrected `can-i`); F2–F4 not run | Run 1 F5; Run 5 Attempt 5 I3 |
| G alerting | BLOCKED | no real receiver |
| H evidence-bundle integrity | Partial; bundle exists for Run 5 Attempt 5; H6 absence check has the EIP/NAT/EBS gap | Run 5/6 |
| I lifecycle phases | I1–I6 PASS (Run 5 Attempt 5); I7–I9 partial (Run 6 destroy; INFRA-041 deviation); **I10 PASS (Run 5 Attempt 1: a real failed install was destroyed through the public lifecycle)**; I11/I12 unrun | Run 5/6; see FND-0004 for the GCP counterexample |
| J exclusions | Recorded | matrix |

## GCP campaign status (from the inventory)

| Stage | Status | Evidence |
|---|---|---|
| Bootstrap inventory | Complete (read-only) | `gcp-bootstrap-inventory.md` |
| Cloud substrate apply | QUALIFIED (behavioral, once) | Attempts 1–3 |
| Provisioner impersonation + install window | MECHANISM + partial behavioral | Attempt 3: impersonation worked, window revoked on failure |
| Platform install → Ready | **FAILED** | Attempt 3: host lacked `gke-gcloud-auth-plugin` |
| Destroy from `Ready` | not reached | — |
| Destroy from partial install | **FAILED** | INFRA-042 |
| Service-networking peering absence | QUALIFIED (behavioral, once) | Attempt 3, verified by API |
| Cloud SQL deletion protection / prepare | MECHANISM (prepared and verified 21 s) | Attempt 2 |
| GCP query matrix / equivalent profile | **does not exist** | inventory remaining gap 7 |

---

## Claims corrected by primary-source verification

The externally supplied packet is retained in `research/` unmodified. These
claims were corrected or discarded (detail in the report and findings):

| Packet claim | Verified result |
|---|---|
| `roles/container.developer` does not authorize Kubernetes workloads | **Refuted** (INFRA-043 / FND-0001) |
| Service Networking `deletion_policy = "ABANDON"` bypasses VPC deletion locks | **Corrected** — resource is `google_service_networking_connection`; ABANDON leaves the peering (FND-0005) |
| GKE 1.26+ plugin requirement cited to the auth page | **Citation corrected** to the cluster-access page |
| AWS VPC/ENI deletion contract cited to `aws_eks_cluster` | **Citation corrected** to VPC-delete + EKS network-requirements pages |
| `aws_rds_cluster` blocks destroy unless `skip_final_snapshot` | **Confirmed**, with the `final_snapshot_identifier` branch |
| Cloud SQL `deletion_protection` defaults protected | **Confirmed**, plus the API-level `settings.deletion_protection_enabled` |
| cert-manager CloudDNS solver exists; cert-manager Route53 uses IRSA | **Confirmed** |

---

## For the next AWS / GCP HARDEN run — the evidence it should collect

Prioritised, provider-tagged, and traceable to a finding/invariant:

1. **GCP (blocks everything):** a run whose platform install reaches `Ready`,
   with the host plugin present; then the success-path `PlatformInstalling →
   Ready` revocation and the positive/negative provisioner probe (FND-0001,
   FND-0003).
2. **AWS (blocks the application half):** implement INFRA-040, then run matrix
   B/C/D and record the observations with their identity (HARDEN-003).
3. **Both:** a destroy that reaches `Absent` under `destroy_retention: none`
   with no manual step, and an absence check that covers EIP/NAT/EBS
   (FND-0006, FND-0003).
4. **GCP:** destroy a deliberately partially-installed platform through the
   public lifecycle (FND-0004); re-observe peering absence and decide
   ABANDON vs `REMOVE_PEERING` (FND-0005).
5. **AWS:** decide FND-0002 and, if narrowed, prove the escalation path is
   denied or explicitly accepted.
6. **GCP:** the capability rows (Cloud DNS solver, persistent workload binding)
   once the platform reaches `Ready` (FND-0007, FND-0009).

## How to update this index

When a finding's status changes, update the finding, then its row here, then the
matching invariant's qualification table. When a run is executed, record the run
identity (`provider`, `target`, `revision`, `profile`, `timestamp`, cleanup
deviations) in the run record and cite it here by that identity. Do not promote
`STATIC`/`MECHANISM` evidence to `BEHAVIORAL` to make a row look green.
