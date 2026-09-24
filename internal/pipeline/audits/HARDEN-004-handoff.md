# HARDEN-004 handoff — GCP qualification, destroy-path recovery (2026-09-24)

**Read this first.** It says what merged, what is open, what is next, and what was verified
rather than assumed. `main` at the time of writing: `f3e9480b`.

## Where the work stands

The GCP qualification campaign has not reached cert-manager, and that is deliberate: two live
attempts (5 and 6) exposed that **Sol could not reliably get back to zero**, which matters more
than reaching further into the stack. The recovery path is being repaired before another live
run.

| Merged | What it did |
|---|---|
| #449 | Offline state-machine suite for the qualification harness (`internal/qualification/gcp/test-live-qual.sh`), wired into CI. Found and fixed: teardown with two owners (phase + EXIT trap), absence probes that read any non-zero exit as ABSENT, a quota check whose `\t` pattern never matched a tab, and a quota read that reported "usage is non-zero" when it could not parse the read at all. |
| #450 | `FND-0030` design recorded before implementing it. |
| #451 | Mechanism 2: eligibility is `configuration INTERSECT state`. Plus the policy vocabulary (`failure_policy`, `preparation_outcome`) — **types only, not wired**. |
| #452 | Honesty corrections: the eligibility rule bounds what may be TARGETED, not what Terraform PLANS; plus the unrepresented-resource warning. |

`FND-0030` is **OPEN**. `INFRA-067` (destroy refused by install-time validation) is fixed.
`DEC-043` (durable zone ownership) is decided and implemented; the zone is adopted into
`cli/platform/infra/bootstrap-gcp` and reconciled by the harness.

## Next steps, in order

### Step 1 — plan-and-assert (own PR) — NOT STARTED

`configuration INTERSECT state` bounds targeting, not planning: `-target` includes
dependencies, and a targeted apply reconciles the whole resource, so ForceNew drift plans a
**replacement** — a create on the destroy path.

Implement the preparation as `plan -target=<eligible> -out`, `show -json`, validate, then
`apply` the saved plan. Rules:

- Allow `["no-op"]` anywhere; `["update"]` only on eligible addresses; `["read"]` only where
  `mode = "data"`.
- Refuse everything else: any create, delete, or replace (`["delete","create"]` **or**
  `["create","delete"]`), and any update outside the eligible set.
- For updates on eligible addresses, **report** (do not refuse) attributes changing besides
  the deletion-protection fields, so destroy-path drift reconciliation is visible.
- A refusal is a preparation failure whose reason names the offending addresses and actions.
- Put the validation in the library as a pure function over **parsed** plan JSON, returning
  the offending changes, so it is testable without a cloud.
- Fixtures: pure guard update (pass); dependency create pulled in by `-target` (refuse);
  ForceNew replacement in both orderings (refuse); data-source read (pass); update outside
  eligible (refuse); empty plan (pass).
- Only after it enforces the property: restore the mechanical guarantee in the comments,
  worded as what the *plan check* guarantees.

### Step 2 — wire the policy vocabulary (own PR; subsumes the `prepared:false` item) — NOT STARTED

`prepare_destroy` → `string preparation_outcome`; `gcp_prepare_destroy` → `unit
preparation_outcome`; `prepare_destruction` → the `destruction_preparation` record (two typed
facts, no redundant pair). GCP guard-lowering and plan-check refusals are
`Continue_to_destroy`; AWS `final-snapshot` is `Block_destroy`. Unreadable state becomes
`Preparation_failed/Continue`, distinct from `Nothing_to_prepare` — which replaces the bool and
resolves the `verify_gcp_destroy_preparation ~prepared:false` ambiguity.

**Exit-code contract (decided by the operator):** `0` only if every preparation succeeded or
had nothing to do **and** the destroy succeeded; a distinct nonzero code for "destroy succeeded
but a preparation failed"; the existing failure code for a failed or blocked destroy. Document
the codes in the CLI help.

Tests: the two specified regressions — Block (destroy never invoked, target remains, the
retention guarantee named) and Continue (failure visible, destroy invoked, result reported
separately) — plus the exit code for each case.

### Step 3 — adoption inspection (read-only) — NOT STARTED

IDENTITY (is this resource associated with this exact Sol target?) separately from AUTHORITY
(is that evidence strong enough to assume Terraform ownership and delete it?). Write up
findings and stop; act on nothing. "Current resources do not carry enough provenance" is a
legitimate and useful result — do not lower the standard to make adoption possible.

## Verified vs assumed

**Verified:** the harness suite passes in CI (`24 passed, 0 failed` in the required `test`
job); 29 OCaml tests pass including the eligibility, complement and policy assertions;
`main` builds; cost exposure is zero (GKE and Cloud SQL absent, only the durable zone
remains); the delegation resolves.

**Assumed / not established:** the plan-and-assert guarantee (not implemented — the comments
no longer claim it); the wired policy behaviour (types exist, path still aborts); whether
current resources carry sufficient provenance for adoption (unexamined); whether the
historical "verify: absent" claims in Attempts 5/6 rested on sound checks (both suspect
checks are fixed now, but the old verdicts should not be re-read as strong evidence — the
independent provider inventory is what established those runs were clean).

## Hard stops

Any terraform apply/destroy against a real account; any spend; opening the Attempt-7 gate; CLI
contract changes beyond the exit codes decided above; any mutation during the adoption
inspection.

## Method notes that cost time

- **After `dune fmt`, re-read the file before writing edit anchors.** Formatting invalidated
  hand-written anchors twice and produced a patch that cut through a comment, surfacing as
  `Unbound value`. Better: format first, generate edits against formatted source.
- **The ticket-move guard needs both ids** when a branch names one ticket and the subjects
  name another, each in its own parenthesised group.
- **Use `git grep` for source-of-truth questions**; a working-tree search missed a
  line-continued literal and nearly withdrew a real finding.
- **Never `git add -A` while a qualification target is in the tree** — it swept a target left
  by a debug run into a commit.
- Evidence: Attempt-6 raw logs frozen at `~/sol-attempt6-evidence/` (outside the repo — they
  carry project identifiers); the readable chronology is
  `docs/qualification/2026-09-23-gcp-attempt6.md`.
