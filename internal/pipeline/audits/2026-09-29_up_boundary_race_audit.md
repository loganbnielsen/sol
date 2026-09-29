# Targeted release-boundary audit — 2026-09-29

Audited canonical `main` and `origin/main` at `4bde298fb8ac0dec96040638bfd690b8a9341aca` after a clean fast-forward. No finding was implemented.

## Reconciliation and scope

BUG-083 is on main from PR #720. PR #721, the support-library API layout, is merged. PR #722 (canonical-main sync policy) and PR #723 (BUG-084–086 cloud inventory findings) remain open; their findings were not duplicated. Existing release-boundary finding BUG-077 is DONE. The prior targeted audit's cloud ownership path was not revisited as a new finding.

Read the roadmap, work summary, production-audit guidance, previous targeted report, current tickets and open PRs. Traced `sol up` and `sol deploy` from command entry through retained-boundary reads, lease acquisition, release recording, and rollback. Checked the release tests and the `sol-jobs` lifecycle and Postgres tests. This is a targeted source audit, not the template's full live runbook or a provider qualification.

## BUG-087 — `sol up --scope` reads its boundary before holding the lease

**Status: Open. Severity: High. Category: Data Integrity / Lifecycle.**

`cli/bin/cmd_up.ml:370-383` calls `Sol_cli_release_store.retained_for_plan` before `Sol_cli_boundary_lease.with_boundary_lease`. That helper reads the current release pointer and record (`cli/lib/deploy/sol_cli_release_store.ml:178-209`). The lease only serializes later apply/record work. A second deploy or rollback can advance the pointer after this read and release its lease before `sol up` acquires it. `sol up` then applies its selected workload and records a complete boundary using the old out-of-scope workload specs and provenance. The current pointer can describe a state that was never applied, and a later rollback to it can restore stale state. The window includes a separate network round trip to acquire the lease.

**Concrete interleaving:** initial boundary has A0+B0; `sol up --scope A` reads B0; another scoped deploy updates B to B1 and releases its lease; `sol up` acquires the lease, applies A1, and records A1+B0. B1 remains live, while the new current release records B0. A rollback to that release applies B0. The same risk exists if a rollback changes the boundary in the window.

**Positive control:** `Sol_cli_deploy_run.apply` (`cli/lib/deploy/sol_cli_deploy_run.ml:260-286`) reads `retained_for_plan` inside `with_boundary_lease`. BUG-077's release tests cover sequential scoped composition and unreadable records, but no competing operation between the read and lease in `cmd_up`. The interleaving is verified by source ordering; it was not executed against a live cluster.

**Remediation:** read and validate the retained boundary only after acquiring the workspace lease, before any mutation. Exercise an intervening pointer change in a command-level regression, and verify that a scoped `sol up` records the boundary current at lease acquisition. Preserve the existing refusal for an unreadable scoped boundary.

## Candidates rejected

- `sol-jobs` lets an application `J.handle` exception escape and recover by lease expiry after process restart. The `JOB` contract requires a `result`, and no realistic high-severity failure beyond that contract was established. No ticket filed.
- Migration Job polling's failed-count path was considered; the generated Job retry policy was not established as a conflicting case. No ticket filed.

## Verification limits

No live Kubernetes, broker, database, provider, or Terraform state was mutated. The race evidence is source ordering plus the documented complete-boundary and rollback behavior; a deterministic command-level race test belongs in the implementation ticket. No code was changed.
