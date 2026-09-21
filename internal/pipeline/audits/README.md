# Sol audit & qualification area

This directory is Sol's **qualification ledger and independent audit function**.
It records, separately, four things that are easy to conflate:

1. **what Sol claims** (architecture, ADRs/DECs, profile contract);
2. **what the providers actually document** (AWS, GCP, Kubernetes, Terraform,
   cert-manager);
3. **what the current implementation does** (read from `main`, not from commit
   messages);
4. **what live HARDEN runs have behaviourally established** — and what they have
   not.

Its job is accuracy, not ticket production. An audit that finds nothing is a
valid result; an audit that invents a defect to look productive is not.

## Layout

```
internal/pipeline/audits/
  README.md                      this file — structure, conventions, vocabulary
  QUALIFICATION_STATUS.md        the compact "what does Sol currently know?" index
  research/                      externally produced source material (not authority)
  findings/                      durable statements about implementation/qualification state
  invariants/                    provider-neutral properties Sol intends to guarantee
  <YYYY-MM-DD>_*.md              dated audit / reconciliation reports (existing convention)
```

Dated reports stay directly in `internal/pipeline/audits/` because that is the
repository's established convention (`docs/audits/AUDIT.md`, the `/audit` skill,
and ADR 0001 all reference them by that path). Historical reports are **not**
moved into a `reports/` subdirectory, because moving 35+ files would be churn
with no semantic gain and would break the existing references. New durable
artifacts (findings, invariants, research) get subdirectories because they are
referenced by stable ID rather than by date.

## The four artifact types

### 1. Research / source material — `research/`

Externally produced or preliminary research. It may be wrong. It is an *index
into primary sources*, never authority. Every file here carries a provenance
header stating that it is unverified and pointing at the report that supersedes
it. Do not silently correct a research packet; its errors are why independent
verification exists.

### 2. Verification reports — dated `*.md` in this directory

One pass of audit work reconciling `primary source → provider contract → Sol
implementation → HARDEN evidence → classification`. Reports are dated and
historical: a later report supersedes an earlier one for *current* conclusions
but does not erase it. The governing report for the 2026-09-19 provider-contract
packet is:

- `2026-09-19_provider_contract_verification.md`

### 3. Findings — `findings/FND-NNNN-*.md`

A **durable statement about Sol's implementation or qualification state**. A
finding does *not* imply a defect and does *not* imply a ticket. Findings are
the general storage mechanism; tickets are not.

Each finding records, where applicable: title; classification **and** state (two
axes, defined below); date
first identified; date/revision last verified; provider(s); the Sol claim or
invariant at stake; the verified provider contract with primary-source URLs and
short exact excerpts; current implementation evidence with paths/line locations;
HARDEN behavioural evidence; the static / mechanism / behavioural evidence
available; what **is** established; what is **not** established; impact; derived
engineering work (ticket IDs) if any; related ADRs/DECs/tickets/runs; and
supersession/resolution history. A historical finding is not deleted when its
defect is fixed — its status and evidence are updated and the history kept.

ID allocation: `FND-NNNN`, monotonic across the directory. Search all of
`findings/` for an existing finding before creating one.

### 4. Engineering tickets — `internal/pipeline/tickets/`

Actionable engineering work only. Ticket policy is deliberately strict:

Create a ticket **only** when all of the following hold:

1. a provider contract or Sol invariant has been independently established;
2. the current Sol implementation has been inspected;
3. there is a concrete implementation defect or missing required safeguard;
4. the finding is actionable in code/configuration;
5. no equivalent ticket already exists.

Do **not** create a ticket because provider behaviour is undocumented, because
something is not yet behaviourally qualified, because an assumption needs a live
test, because two providers differ, because a source is ambiguous, because a
HARDEN acceptance criterion is unexercised, or because an improvement might be
useful. Those are findings/invariants/qualification status. Every new ticket
must name the finding that backs it, and every finding with derived work names
the ticket.

A `DESIGN_GAP` whose question has since been **decided** is no longer blocked by
rule 3: once the decision is recorded (e.g. a `DEC-*`), the implementation becomes
concrete work and gets a ticket. A `DEC-*` records the decision; the `INFRA-*`
that follows implements it.

## Shared vocabulary

### Classification and state are separate axes

Every finding carries **both**. Classification is what kind of thing the finding
*is* and rarely changes. State is where it currently stands and changes as work
lands and evidence accumulates. History is preserved by updating **State** and
adding a dated line — never by rewriting the classification or the earlier
conclusion. (Example: a `VERIFIED_DEFECT` moves `OPEN → FIXED_UNQUALIFIED →
QUALIFIED` over its life and keeps the same classification throughout.)

**Classification — what the finding is**

| Classification | Meaning |
|---|---|
| `VERIFIED_DEFECT` | A provider contract or Sol invariant is established, the implementation inspected, and a concrete defect / missing safeguard exists. |
| `DESIGN_GAP` | The stated invariant or claim and the implementation's design are not aligned, **and** closing the gap (or deliberately restating the claim) requires a design decision — not a mechanical fix and not a measurement. Includes invariant-scope ambiguity. Recorded so the decision is explicit. |
| `QUALIFICATION_GAP` | The property is not yet behaviourally established. Not necessarily a defect. |
| `DOCUMENTATION_GAP` | The code/docs claim something the verified provider contract does not support — a pure claim error (stale, too broad, wrong page). If the claim is overbroad because the *design* cannot realize it, use `DESIGN_GAP`. |
| `OBSERVATION` | Recorded because it matters to future readers; no defect. |

**State — where it stands (orthogonal, mutable)**

| State | Meaning |
|---|---|
| `OPEN` | The issue/gap exists; no change landed, or the behavioural row is not established. |
| `FIXED_UNQUALIFIED` | An implementation change landed and is `STATIC`/`MECHANISM`-verified, but the behavioural postcondition is not yet established. Code correctness and behavioural qualification are distinct. |
| `QUALIFIED` | Behaviourally established, with the run/attempt and target/revision named. |
| `BLOCKED` | Cannot progress until an external input exists (e.g. a real alert receiver, a delegated DNS zone). |
| `ACCEPTED` | A deliberate, recorded residual; not being fixed. The reasoning lives in the finding. |
| `SUPERSEDED` | Replaced by later verified evidence; retained for history. |

### Evidence taxonomy

Use these three words precisely and never promote one into another:

| Tier | Meaning | Examples |
|---|---|---|
| `STATIC` | Source/configuration/rendering/unit/structural evidence. | Terraform contains the intended grant; a rendered Secret name matches its reference; a parser propagates a retention field. |
| `MECHANISM` | The intended mechanism executes or changes state. | A bootstrap binding is removed; impersonation succeeds; deletion protection is lifted. |
| `BEHAVIORAL` | The externally meaningful property is demonstrated. | After closure, a bootstrap-only operation is denied; a required steady-state operation still succeeds; provider APIs report the target absent; a real DNS-01 certificate is issued. |

A successful `terraform apply` is never behavioural evidence of provider-side
absence, and a green offline harness is never behavioural evidence of a live
property. A `kubectl auth can-i` result is behavioural *only if* the identity
performing it and the authorizer it exercises have themselves been established
(HARDEN-003).

### Historical evidence discipline

Every behavioural claim should name, where available: provider; HARDEN
run/attempt; target; executed code revision; profile/config; observed result;
cleanup deviations; and whether normal lifecycle or emergency cleanup produced
the final state. If a historical record does not establish one of these, the
finding says so rather than filling it in. Later code on `main` does not change
what an earlier run actually executed.

## Mutation verification

A mutation test is evidence only when **the mutated build succeeds and the intended test
then fails**. A compiler rejection is an *invalid* mutant, not a killed one; and when a
build fails, the test binary that runs is the previous one, so its exit code says nothing
about the mutation. Mutate the body of the live code path, check the build's exit status,
then read the test result. (Learned the hard way: see DEC-040.)

## Primary-source policy

For provider-contract claims, use primary sources (AWS, Google Cloud,
Kubernetes, HashiCorp/provider, cert-manager, official CLI docs) and include
direct URLs. Verify the cited page actually supports the claim; a citation is
not evidence. Preserve short exact excerpts; distinguish documented guarantees
from documented behaviour/configuration requirements; mark ambiguity explicitly.
When a Terraform Registry page is a JavaScript shell, read the generated
Markdown in the provider's own repository — it is the same text the registry
renders.

## Working alongside other actors

The ledger is shared, and two rules here were learned expensively:

- **Never remove a worktree.** A worktree can hold its owner's uncommitted review
  edits, and removing it destroys them with no trace in git — `git status` being
  clean at the moment you look does not prove the owner is finished with it
  (#365, repeated on 2026-09-20). Leave worktrees in place, or report them;
  removing one is the owner's call.
- **Never `git add -A` while a qualification target is in the tree.** A real
  target sits untracked at `sol/qual/…` by design, so a blanket add sweeps it into
  the commit — the HARDEN-002 run 2 incident, reproduced on 2026-09-20 by an agent
  that had read that incident's own comment. Stage explicit paths. When a
  qualification target is present, `git status` should show exactly one `??` entry
  and every add should name what it is adding.
- **Publishing a branch is not owning it.** When an item's branch is committed
  but unpublished, publishing it and opening its PR is shepherding and is fine;
  rewriting its commits is not, and the PR body should name who authored it. The
  repository refuses to merge a branch that is behind `main`, so landing several
  independent items one at a time costs a full CI cycle each; when the items do
  not overlap, one integration branch with a single CI run is cheaper — and the
  per-item PRs stay as the review record. Every item still lands on its own
  gates: review against its acceptance criteria, its guards and mutation tests
  run, and CI green before merge.
