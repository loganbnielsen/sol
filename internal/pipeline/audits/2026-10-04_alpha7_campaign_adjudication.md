# Alpha.7 cloud campaign adjudication — 2026-10-04

Source: the uncommitted `CAMPAIGN-FINDINGS.md` in the `sol-aws-run9-preflight` worktree, AWS attempt 2, GCP attempts 1–5 and `/tmp/sol-gcp-alpha7-run1/` evidence. This is the durable disposition; the scratch file remains with its owner. The released artifact and current main are different baselines.

| Finding | Disposition |
|---|---|
| A1 / P1 / P1a | BUG-205 already has a dedicated implementation branch. The observation is AWS registry presence checking; GCP's plan path did not reproduce it. Do not broaden the ticket to all providers. |
| A2 | BUG-206. One shared timeout boundary, mechanism still unproven. GCP API probes failed from the harness host; post-failure capture contained no Redpanda pods, PVCs or Helm release Secret. Neither observation proves why Helm failed. |
| A3 | BUG-207. The install window is revoked on failure as intended, but subsequent apply must be able to reopen it for bounded reconciliation. GCP revocation was seen; only AWS retry denial was observed. |
| A4 | No new ticket. Current main's `Sol_cli_aws_destruction.prepare` applies `rds_deletion_protection=false` before destroy, unlike alpha.7. Live requalification is still required; do not credit the old run as a pass. |
| A5 | DEC-039 assigns operator application diagnostics and reserves broad platform access for `cluster-access`; qualification transport is separate. No new broad operator grant. The failed-install diagnosis gap is handled by BUG-206 evidence capture and BUG-207 authorized reconciliation. |
| A6 | No defect filed. Current `Sol_cli_terraform_vars.var_file` resolves an explicit `--var-file` from the caller cwd and a target-declared path from the workspace root, both to absolute paths before Terraform `-chdir`. The reported workspace resolution is consistent with running from the workspace. The harness default is absolute. |
| A7 | BUG-208. Derived GCP account IDs need preflight validation. |
| A8 | Provider capacity incident, resolved when us-central1 provisioned on attempt 5. No product ticket or region change. |
| H1–H2 | INFRA-103. Both make AWS ownership/absence evidence inaccurate. |
| H3 / P2 | INFRA-104. The local patch is unpushed; the target must declare the reference service's managed resources. |
| H4 | INFRA-105. A phase-dependent artifact was incorrectly required for every failure. |
| H5 | INFRA-106. Harness survival and teardown must not depend on stdout readers. |

## Contract decisions

**Q1 — target identity.** Each disposable qualification run uses a fresh environment name and state key, matching the campaign's clean-start condition. A fixed `qualreg/...` name can name a logical row, but its old state cannot be silently inherited as a new first-run verdict. Update harness defaults when implementing the next run ticket.

**Q2 — managed dependencies.** The alpha reference scenario declares `orders_svc` using `app_db` and `events`; the cloud rows exercise managed Postgres and broker. The GCP harness's Cloud SQL variables agree. H3's omission was a harness defect, not a change to the scenario.

**Q3 — matrix vocabulary.** The GCP harness phases `cloud`, `platform`, and `app` are execution stages, not alpha acceptance rows. `cloud` supplies alpha F1 and I1/I2 prerequisites; `platform` supplies I2, E7 and substrate prerequisites; `app` supplies B1/B3/B4, C1, F2 and other rows only when their own independent assertions run. `destroy` and `verify` supply I5/I6 and the provider matrix's absence rows. No phase completion alone grants a matrix PASS; each alpha row cites its corresponding provider-matrix row and run evidence.

## A2 mechanism boundary

The shared Terraform resource has `timeout = 600`; both reported roughly 700-second platform failures. GCP's prerequisite apply completed, followed by ten failed API probes during platform apply. A post-failure capture showed Ready nodes but no Redpanda installation objects. Node startup events include temporary scheduling and mount errors; they do not establish a causal Redpanda stall. The evidence supports a failed Kubernetes/Helm interaction after prerequisites, not a specific endpoint, firewall, chart or timeout root cause. BUG-206 requires a timestamped first failing operation before selecting a fix. No further live run is authorized by this filing.
