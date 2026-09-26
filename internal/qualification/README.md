# Qualification ledger

Live qualification asks one question: **does reality independently confirm what Sol claims?**
This directory holds the evidence for that question: the per-run records, the executable
contracts (matrices), and the procedures. Where each provider currently stands is summarised in
`internal/pipeline/audits/QUALIFICATION_STATUS.md`; this file is the index and the rules.

## How qualification is tracked

- **Standing goals are not tickets.** "Qualify the production profile on AWS/GCP" never finishes,
  so it lives here and in the matrices, not in `internal/pipeline/tickets/`. (HARDEN-002 and
  HARDEN-004 were such epics; both were closed on 2026-09-24 and their history moved here.)
- **Each live run is a ticket** that can finish: it names the matrix rows it intends to qualify,
  its preconditions and its cost gate. It starts in `BACKLOG` with a `## Blocked On` section for
  the explicit operator authorization, and is promoted only when that authorization is given.
- **Each run produces a record** from `run-record-template.md`, named `<date>-<provider>-<run>.md`.
- **Defects a run finds** become findings (`internal/pipeline/audits/findings/`) and ordinary
  tickets, credited to the ticket that fixes them, not to the run.
- **Updating `QUALIFICATION_STATUS.md` is part of every run ticket's acceptance criteria.**

## Operating rules

Moved verbatim on 2026-09-24 from HARDEN-004's "Standing constraints". Written for the GCP
workstream; they apply to every provider's live runs.

1. **Cost rule, absolute.** Never wait for user input while billable qualification
   resources exist. On any blocker — a defect, a semantic or security decision, a
   missing prerequisite, an external dependency — the order is: preserve evidence →
   tear down → independently verify `Absent`/cost-clean → only then ask. Tearing
   down is part of qualification, and `terraform destroy` succeeding is *not*
   evidence of cost-cleanliness; the project must be inventoried.
2. **`Absent` is the postcondition for a disposable target.** No residual billable
   storage, snapshots, retained buckets, addresses, disks or load balancers, unless
   retention itself is the scenario. Production retention semantics are deliberately
   undecided (DEC-033) and GCP cannot express retention at all, so a GCP target whose
   `destroy_retention` is the `final-snapshot` default is **refused by name** rather
   than destroyed.
3. **Do not build cert-manager or Workload Identity speculatively.** Build them when
   a live attempt has reached the boundary that needs them. TLS issuance is
   **BLOCKED** — the qualification name is not delegated to the qualification
   project — and a blocked row is recorded as blocked, never as qualified. The
   owner controls `sol-fab.dev`, and `DEC-042` is now **decided**: `qual-gcp.sol-fab.dev`
   as its own Cloud DNS zone in `sol-qualification`, created by Sol's cloud root and
   delegated from the Squarespace-managed parent by hand (four `NS` records), with a
   scoped cert-manager identity. So this row is no longer waiting on a decision — it is
   waiting on implementation and the delegation itself. The rest of the workstream does
   not depend on it. (`qual-aws.sol-fab.dev` is reserved for the AWS profile; the
   delegation requirement follows from proving public TLS, not from GCP.)
4. **Never create long-lived service-account JSON keys.** Impersonation and
   short-lived tokens only.
5. **Do not weaken or restructure AWS behaviour to accommodate GCP.** Shared-definition
   changes keep the AWS contract and carry regression coverage.
6. **Preserve Terraform's ownership and dependency graph.** Terraform owns resource
   dependency and state mechanics; Sol owns semantic lifecycle transitions, authority
   boundaries, readiness semantics, evidence and cross-tool orchestration. Do not
   reproduce the resource DAG in OCaml.
7. **Evidence classes.** Static/configuration, mechanism/renderability, and live
   behavioural are different claims. Only the third satisfies a production
   behavioural claim, and a stub written from the implementation is not evidence
   about the tool it models.

## Lessons learned (with the evidence that taught them)

1. **Act on the process identity you launched, never on a pattern.** `pkill -f 'live-qual.sh cloud'`
   matched the operator's own shell, and killing the harness left its `terraform apply` running
   unnoticed (Attempt 6: `2026-09-23-gcp-attempt6.md`).
2. **Never force-unlock a lock whose holder may be alive.** In Attempt 6 the liveness check printed
   the live `terraform apply` and the unlock ran anyway; a live apply then finished against a
   broken lock.
3. **Never signal a Terraform provider plugin.** A SIGTERM to Terraform *and* its provider during an
   in-flight GKE create cancelled the call, so the cluster existed in GCP and not in state — the
   divergence behind FND-0030. Had only Terraform been interrupted, the Google provider's create
   path is written to persist the in-flight `operation` and return
   (`resource_container_cluster.go`, v5.45.2 — read from source, not observed live).
4. **Pull state before any teardown or recovery** (`terraform state pull` into the evidence bundle).
   Attempt 6 could not be replayed offline because no state snapshot was kept.
5. **Freeze run logs outside Sol's run directory.** Sol prunes to the latest 20 runs, shared across
   commands; a test burst once pruned every qualification run directory (INFRA-075).
6. **A finding names the actor and the action**: product, harness, operator, Terraform, or provider.
   FND-0030 described "an apply interrupted after creation" and dropped *who* interrupted it and
   *how*; the analysis built on it treated an operator action as a product behaviour.
7. **One setting per value.** A harness `-var=create_dns_zone=true` silently overrode the var-file's
   `false` (Attempt 6).
8. **The harness is part of the system under test.** A refactor deleted `destroy_vars` and the
   teardown ran with no variables (Attempt 6); the offline harness suite exists because of it.
9. **Keep the target file until teardown is verified**; destroy needs it (Attempt 5).
10. **Terraform's exit status is not the cost verdict for qualification**; the independent provider
    inventory is. That inventory belongs to qualification, not to the product runtime
    (`internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`).
11. **Resolve DNS over HTTPS in this environment**; port 53 is blocked, so `dig` waits are unreliable
    (Attempt 5).

## Record index

| Provider | Run | Record |
|---|---|---|
| AWS | Run 1 (blocked) and remediation | `2026-09-17-aws-run1.md` |
| AWS | Run 2 | `2026-09-17-aws-run2.md` |
| AWS | Runs 3 and 4 | `2026-09-18-aws-run3-run4.md` |
| AWS | Run 5 attempts 1, 2, 3, 5 | `2026-09-18-aws-run5-attempt1.md`, `2026-09-19-aws-run5-attempt2.md`, `2026-09-19-aws-run5-attempt3.md`, `2026-09-19-aws-run5-attempt5.md` |
| AWS | Run 6 attempt 6 | `2026-09-19-aws-run6-attempt6.md` |
| AWS | Run 7 attempt 7 | `2026-09-19-aws-run7-attempt7.md` |
| AWS | Run 8 | `2026-09-20-run8-aws.md` |
| GCP | Attempts 1–4 | `gcp-bootstrap-inventory.md` |
| GCP | Attempt 5 | `2026-09-22-gcp-attempt5.md` |
| GCP | Attempt 6 | `2026-09-23-gcp-attempt6.md` |
| GCP | Attempt 7 (stopped pre-live) | `2026-09-24-gcp-attempt7-prelive-falsification.md` |

| Contract / procedure | File |
|---|---|
| AWS profile matrix | `production-single-region-v1-matrix.md` |
| GCP profile matrix (+ machine-readable rows) | `gcp-production-single-region-v1-matrix.md`, `gcp-production-single-region-v1-matrix.tsv` |
| AWS run procedure | `aws-run-procedure.md` |
| Run record template | `run-record-template.md` |
| Next runs | HARDEN-007 (AWS, `BACKLOG`, authorization-gated); HARDEN-006 (GCP) **ran** on 2026-09-25 — see `2026-09-25-gcp-attempt8.md` |

**GCP Attempt 8 ran on 2026-09-25** (`main @ dae9540d`, after a pre-live Phase-0 stop and two
corrective harness PRs). It established FND-0010's cause — `TLS_CA_OR_CERTIFICATE`: the webhook was
reachable and served TLS, the API server rejected its certificate, and the webhook configuration's
`caBundle` was uninjected at check time. **The reachability hypothesis is falsified and no firewall
rule is warranted.** `Ready` was not reached. The destroy degraded rather than completing the
platform teardown (`FND-0058`). Record: `2026-09-25-gcp-attempt8.md`; stop that preceded it:
`2026-09-25-gcp-attempt8-phase0-stop.md`.

Its harness was re-scoped on 2026-09-25 (HARDEN-006): it exists to establish the cause of the
cert-manager `startupapicheck` failure (FND-0010) — from the check's own output, classified, before any
teardown — with platform `Ready` as the alternate outcome. The harness
(`internal/qualification/gcp/live-qual.sh`) generates a target with no `cluster_issuer`, because a GCP
target that asks for one is refused at install time and would stop the run before cert-manager; and it
captures the discriminator in that same invocation. Read the harness header for the phase model and
`evidence-manifest.txt` for what a bundle contains.
