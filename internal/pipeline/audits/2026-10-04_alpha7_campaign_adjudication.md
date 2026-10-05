# Alpha.7 cloud campaign adjudication — 2026-10-04

Source: the uncommitted `CAMPAIGN-FINDINGS.md` in `sol-aws-run9-preflight`, AWS attempt 2, GCP attempts 1–5, `/tmp/sol-aws-alpha8-run1/` and `/tmp/sol-gcp-alpha7-run1/`. AWS attempt 1 used released alpha.7; subsequent AWS observations used the locally patched artifact carrying BUG-205. GCP attempt 5 used released alpha.7 with the local harness target correction. These are distinct baselines; no local patch is credited as merged.

| Finding | Disposition |
|---|---|
| A1 / P1 / P1a | BUG-205 already exists in the campaign branch with its patch and regression case, unmerged. The observed failure is AWS registry presence checking; GCP plan did not reproduce it. |
| A2 | BUG-206. The missing broker Secret is a concrete fresh-install prerequisite mechanism. Exact live attribution requires confirming whether it was supplied manually. The proposed API-unreachable discriminator is invalid for attempt 5 (timeline below). |
| A3 | BUG-207. Trace the actual retry entry point and effective temporary grant. GCP grant removal is observed, but its retry failure is not. AWS's missing cloud-provisioner access entry is intentional under DEC-034 and cannot prove acquisition failed. |
| A4 + H1 | BUG-209: shared product address mismatch. The resources are counted, not module-qualified. Unindexed import addresses are invalid; exact unindexed state lookup skips RDS protection-disable preparation. This remains on current main. |
| A5 | DEC-034/039 give cluster-access platform administration and operator application diagnosis. Cluster-wide `helm list -A` denial does not establish denial within `redpanda`. Deploy/operator denial there is intended. Diagnose per namespace as cluster-access; no new broad operator grant follows. |
| A6 | No current defect established: `Sol_cli_terraform_vars.var_file` resolves explicit flags from cwd and target-declared paths from workspace root. The reported flag behaviour needs the exact invocation/cwd trace before a ticket can claim the opposite. Use absolute paths in qualification. |
| A7 | BUG-208: derived GCP service-account ID preflight. |
| A8 | Provider capacity incident; attempt 5 provisioned in us-central1. No product ticket or region move. |
| H2 | INFRA-103: exclude deleted NAT gateways and terminated instances from live residue. |
| H3 / P2 + Q2/Q3 | INFRA-104: align target resources and app driver with the alpha orders scenario in both languages. |
| H4 | INFRA-105: require classifier evidence only for reached phases. |
| H5 | INFRA-106: teardown must survive loss of stdout consumers. |
| Q1 + stale attempt evidence | INFRA-107: bind disposable state keys, kubeconfig and captured files to one attempt. |

## Contract resolution

**Q1.** The campaign's clean-start condition requires a fresh disposable environment/state key per run, while durable bucket and zone stay intact. Reusing a logical row label is fine; silently inheriting its prior state or evidence is not. INFRA-107 implements the harness constraint.

**Q2.** The alpha orders scenario uses managed Postgres and Kafka on cloud targets. The declaration's `uses: [app_db, events]`, GCP Cloud SQL variables and alpha reference contract agree. Omitting those resources is a harness input defect.

**Q3.** `cloud`, `platform` and `app` name execution stages, while alpha and provider matrices name claims. Cloud/platform stages produce prerequisites and lifecycle/substrate observations for alpha F1/F2, E7 and I1/I2; destroy/verify produce evidence for I5/I6 and provider `INV-DESTROY-*`/`INV-RET-*` claims only when the corresponding assertion actually runs. The current app driver posts `/charges` and reads `/notifications`; it does not qualify alpha orders/outbox/jobs rows B1/B3/B4. INFRA-104 owns connecting the new reference scenario and recording an explicit per-assertion mapping. No phase exit code alone grants a row PASS.

## A2: reconstructed timeline and mechanism

| UTC time | Evidence | What it establishes |
|---|---|---|
| 21:48–21:49 | `platform-failure/*` and `fnd0010-classification.txt` mtimes, matching node startup timestamps | Capture belongs to attempt 4, before attempt 5 starts. It cannot diagnose attempt 5. |
| 22:20:11 | waiter journal immediately says credentials exist | Old same-name kubeconfig accepted before the new cluster exists. |
| 22:20:17–22:23:14 | ten API probe samples | Old configured endpoint `34.61.46.246`; new provider endpoint later `136.114.238.8`. Probe ends during cloud provisioning, before platform apply. |
| About 22:32 | cloud apply duration 716.1 seconds | New cloud resources provisioned. |
| 22:33:01 | saved state: cert-manager first-deployed | Prerequisite Helm install reached the current cluster. |
| 22:34:55 | saved state: Redpanda revision 1 first-deployed, status `failed` | Helm submitted Redpanda; eight sibling charts are recorded deployed. A general inability to reach the API throughout install is contradicted. |
| About 22:45 | platform duration 689.9 seconds | Redpanda returned `context deadline exceeded`; exact pod/hook condition was not captured for this attempt. |
| 23:01:52 | saved platform-state capture | State includes the failed Redpanda release and successful sibling charts from attempt 5. |

Rendering local pinned chart `26.1.11` with the saved Redpanda metadata values produces mandatory `redpanda-users` Secret mounts in the StatefulSet and post-install Job. The chart does not create this external Secret. Both harnesses omit its creation; the CLI's fresh install creates the namespace and immediately proceeds to Helm. FEAT-093 explicitly requires operator-owned credential input, and the production guide says the release cannot start without it. This establishes a concrete missing-prerequisite mechanism, independent of API reachability. If the operator did not create the Secret in each new cluster, these volumes cannot mount and the release cannot converge. Confirmation of manual Secret creation and contemporaneous mount/hook events is still needed to attribute the observed live timeout conclusively. No timeout change is selected.

The historical GCP bootstrap snapshot is preserved under `internal/qualification/records/2026-09-18-gcp-bootstrap-inventory.md`. Its old operative path now holds only a historical pointer and durable IAM, ownership and inventory rules. Present billing/API/resource state belongs to each run's provider inventory.
