---
id: HARDEN-007
type: verification
severity: high
title: AWS qualification run 9 — the alpha acceptance matrix's aws rows on a production-single-region target
source: internal/qualification/ALPHA_CAMPAIGN.md §6 (T5) — the AWS half of the live campaign
---

**Depends on:** INFRA-060, INFRA-062, INFRA-076, RELEASE-006, FEAT-132, VERIF-027.

**Related:** FND-0020, FND-0022, INFRA-051, FND-0021, DEC-039, DEC-040, DEC-045, DEC-062,
DEC-063, FEAT-134, HARDEN-002 (closed epic).

## Blocked On

**Authorization is given** (2026-10-04, AWS only; GCP withheld), and the host and account gates
from the first preflight are cleared: the `sol-qual` SSO session is live, `dig` is installed
(`dig +short NS qual-aws.sol-fab.dev` answers the four nameservers), the target exists, and the
durable prerequisites are verified present — state bucket `sol-qual5-876701109436-tfstate`, lock
table `sol-qual5-tflock`, the delegated `qual-aws.sol-fab.dev` zone, and all six roles
(`sol-qual5-{provisioner,cluster-access,deploy,operator,publisher,qualifier}`). The account was
clean before the run: no clusters, EIPs, volumes or load balancers.

**Attempt 2 (2026-10-04) is blocked by a product defect, not by a gate.** Running the published
`v0.1.0-alpha.7` bundle against a *fresh* target (`qualalpha7/aws/us-east-1`, a new state key)
stopped at `sol cloud plan`:

```console
[terraform-plan] ok (7.6s)
error: terraform state list failed with exit 1
```

That is `BUG-205`: an environment whose Terraform state does not exist yet is reported as
*unreadable* rather than *holding nothing*, so a never-applied target cannot be planned, applied
or deployed. No resource was created and nothing was billed. The fix and its regression test (the
first-run test now drives a state that has never been written) are on `BUG-205`'s branch, unmerged,
and **`v0.1.0-alpha.7` is published and immutable and cannot carry them**.

**Therefore this run needs a new candidate** built from a revision containing `BUG-205`'s fix
(`RELEASE-006`'s next version), and then the whole matrix is run fresh on that bundle — not on
alpha.7, and not by seeding alpha.7's environment to work around the defect.

Promote to `READY_FOR_ENGINEERING` when that candidate exists.

## Goal

Qualify the alpha acceptance matrix's `aws` rows (`internal/qualification/ALPHA_CAMPAIGN.md` §3)
against the frozen reference scenario (§2, `FEAT-131`/`FEAT-132`) on a fresh
`production-single-region` target. This is the run that replaces the HARDEN-002 frontier: Run 8
stopped at §B3 `NOT REACHED` for two documented reasons — no qualification-only transport to
private application services (`FND-0020` / `INFRA-060`) and no defined way to re-establish a
workload fixture (`FND-0022` / `INFRA-062`) — and both are now resolved.

The operational package is prepared, so authorization is the only design gate left:

- `internal/qualification/aws/aws-run-procedure.md` § *Run 9 — authorization → execute*: the
  per-alpha-row map, prerequisites, the five production identities, expected resources and
  cost-bearing steps, the phase-by-phase evidence, the failure injections, the teardown and
  independent absence verification, the `VERIF-021`/`VERIF-022` collection, and the
  released-bundle interface.
- `internal/qualification/aws/production-single-region-v1-matrix.md` § *Before the next run
  (Run 9)*: the matrix-side reconciliation.
- `internal/qualification/aws/live-row.sh` now establishes and verifies the qualification
  transport (`transport` phase) and drives B3's `-svc` half through it by default
  (`TRANSPORT=1`), with the production identities' `pods/portforward` surfaces recorded before
  and after.

Also re-check whether `sol deploy` can write `sol-deploy-state-<workspace>` (the Run 8
post-boundary observation that shares `INFRA-051`'s root cause).

## Acceptance criteria

- Run under the operating rules in `internal/qualification/README.md` and the procedure in
  `internal/qualification/aws/aws-run-procedure.md` § *Run 9 — authorization → execute*; the
  workload is the alpha reference application, not the pre-campaign `charge_svc`/`notify_worker`
  pair.
- **The run uses the released bundle** (`RELEASE-006`), not a checkout build: `SOL_HOME` unset,
  `sol --version` equal to the bundle version, and the bundle version recorded in the run
  identity (alpha rows A1/J3).
- `terraform state pull` captured into the evidence bundle before any teardown.
- A run record `internal/qualification/<date>-aws-run9.md` from `run-record-template.md`, with
  each targeted alpha/matrix row qualified, blocked or not reached, and the run identity
  carrying the bundle version and the migration-runner digest.
- **`INFRA-060`'s live criterion**, which is this run's to establish and record (the ticket closed
  on the capability and hands it here): the qualification transport established through
  `sol:qualifiers` and its effective surface verified; B3's `-svc` half driven through it; and the
  production identities' surfaces shown unchanged afterwards, including that none of them holds
  `pods/portforward`. The record names the transport identity separately from the identities under
  qualification (DEC-039 §4).
- **The migration runner is published by the harness and handed to Sol by digest** before any
  `sol migrate apply`/`sol deploy` step (`SOL_MIGRATION_RUNNER_IMAGE`; SEC-011, `INFRA-100`).
- **The five production identities** are exercised as declared: provisioner, cluster-access,
  deploy, operator and publisher (the Run 5 text named four and omitted cluster-access;
  § *Run 9* corrects it), with the scoped-identity probes performed as the identity that
  produced them.
- **`VERIF-021` is collected inside this target** (managed secret projection and the fenced
  grant; § *Run 9* § VERIF-021). **`VERIF-022` is recorded blocked on `FEAT-134`**, since
  DEC-063's projected-token volume and caller API are not implemented — blocked, not weakened,
  not substituted by the callee-side JWKS verification alone.
- Rows the run does not reach stay `NOT RUN` with the reason; inspection/mechanism evidence is
  never promoted to behavioural (matrix § Governing rules).
- Teardown to `Absent`, verified independently of Sol's report, including the matrix H6 classes
  and the durable Route 53 zone unchanged.
- The rows this run qualifies carry its verdicts, each citing this run's record.

**Demo/example coverage:** not applicable — this is a qualification run, not an app-author
surface change. The runnable proof is the AWS harness and its offline self-test
(`internal/qualification/aws/test-live-row.sh`).

**TypeScript parity (DEC-022):** no application-facing contract change. The TypeScript namespace
is not in the production profile (DEC-026 §2); E5's parity requirement belongs to `FEAT-134`.

## Prerequisites and remaining blockers

Prepared and non-live (no AWS resource created, nothing spent):

- The transport integration and the released-bundle/migration-runner contracts are wired into
  the harness and pinned by `internal/qualification/aws/test-live-row.sh` (56 assertions),
  including the adversarial cases: a production identity that holds `pods/portforward`, an
  establishment that refuses, a missing transport principal, a worker that never writes, and a
  port-forward that never opens.

Still open, each precise:

1. **Operator authorization** for the live, billable run (and the `RELEASE-006` version).
2. **`RELEASE-006`** — the released bundle the run must use (alpha A1/J3).
3. **`FEAT-132`** — the OCaml reference application the run drives.
4. **`VERIF-027`** — the local integrated run that turns the local rows into verdicts first.
5. **A `sol-qual` SSO session** for the qualification account.
6. **`FEAT-134`** — the DEC-063 implementation, without which alpha E5 (`VERIF-022`) cannot be
   collected.
7. **A real alert receiver with an owner** — only for AWS matrix G1–G3; otherwise G is recorded
   blocked, unchanged since Run 1.

## Disposition (2026-10-03) — prepared, live/operator blocked

Requires explicit operator authorization for a live, billable AWS run. `INFRA-060` and
`INFRA-062` have landed; `RELEASE-006`, `FEAT-132` and `VERIF-027` are the remaining code
prerequisites, and `FEAT-134` is `VERIF-022`'s. The run package is otherwise complete, so
execution can begin once authorization arrives and the prerequisites are `DONE`.

Gated on explicit authorization and/or the live reference-app campaign; see AGENTS.md
§ Live qualification.
