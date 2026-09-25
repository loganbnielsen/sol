---
id: INFRA-076
type: bug
severity: high
title: Terraform must survive Sol, with durable output, a supervisor that records completion, and a graceful signal boundary
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** INFRA-075.

**Related:** DOCS-022, REFAC-094, HARDEN-004

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S4. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

**Premise verified 2026-09-24:** `Sol_cli_process.run` gives Terraform stdout/stderr pipes only Sol reads (`cli/sol/lib/sol_cli_process.ml:184-196`) and `Sol_cli_run_log.run_phase` writes the phase log only after exit (`sol_cli_run_log.ml:188-207`). Reproduced locally with `terraform_data`: closing the wrapper's read end kills Terraform with SIGPIPE (rc −13 after 5.1 s), leaves the lock held, and loses the in-flight resource from state.

**Sequencing:** preferred after DOCS-022, but not blocked on it; supervision is justified whatever DEC-045 decides. REFAC-094 must not merge before this ticket is `DONE`.

## Remediation

One design unit (plan § S4): Terraform output to durable files Sol tails; a supervisor that outlives Sol, launches Terraform in its own session, and records `{pid, host, started_at}` then the exit status or terminating signal; one SIGINT to Terraform's pid only on interrupt (never to provider plugins, never by name, no SIGKILL/timeouts, never force-unlock); three operation states, **Running / Resolved / Unresolved**, as defined in the plan (a graceful non-zero exit after Ctrl-C is Resolved); `errored.tfstate` detected, preserved and reported, never auto-pushed; a clear message when Sol exits while Terraform continues and holds the lock. The qualification harness adopts the same process-identity rules.

**First decision:** the test provider. `terraform_data` has no plugin process, so it cannot prove plugins are not signalled; use a tiny in-repo test provider with a slow Create, or a vendored `null`/`time` provider, hermetically.

## Acceptance criteria (offline)

- The SIGPIPE failure reproduces against the old path and no longer occurs.
- Sol killed mid-apply: Terraform continues, output keeps being written, exit status recorded, lock released, state complete.
- One Ctrl-C reaches Terraform only; the provider plugin process receives no signal from Sol.
- Running / Resolved / Unresolved each classified correctly, including graceful non-zero → Resolved; Unresolved refuses an ordinary constructive retry.
- `errored.tfstate` → loud failure, file preserved.
- Unrelated Terraform processes are untouched.
- `internal/qualification/*` no longer uses `pkill -f` or force-unlock.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
