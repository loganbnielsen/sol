---
id: INFRA-012
type: infra
severity: medium
source: DEC-020 / FEAT-059 deadlock, 2026-09-11
---

**Depends on:** None.

# A prose mention on the `Depends on:` line becomes a dependency, and a cycle silently deadlocks the queue

## Problem

The dependency parser reads **every ticket id on the `Depends on:` line**, regardless of the prose around it. So a line written for a human becomes a claim about ordering:

```
**Depends on:** DEC-016 (environments are targets). Implemented by FEAT-059.
```

produced a dependency on `FEAT-059`. Since FEAT-059 carried `**Depends on:** DEC-020. Replaces the enforcement half of FEAT-058 … Related: DEC-016.`, that also produced dependencies on `FEAT-058` and `DEC-016` — and DEC-020 and FEAT-059 became **mutually blocking**.

Both failure modes are silent:

- The queue simply shows `blocked: <ticket> in READY_FOR_ENGINEERING` forever, which is indistinguishable from "waiting on real work".
- A **cycle** is reported as an ordinary block, so `DEC-020` and `FEAT-059` were both un-actionable with nothing saying why. The work the cycle covered was invisible until the queue was read closely.

Note that the ids involved were all *real* tickets, so "warn on unknown ids" would not have caught it. The defect is the parsing rule, not the vocabulary.

## Proposed fix

1. **Detect cycles.** If the dependency graph contains one, report it as such — naming the cycle (`DEC-020 → FEAT-059 → DEC-020`) — rather than presenting it as an ordinary block. This is the substantive fix: it turns a silent deadlock into a loud, diagnosable state.
2. **Validate the line.** `Depends on:` takes a comma-separated list of ids and nothing else; warn when other content appears, so a prose mention is flagged where it is written rather than surfacing as a mystery block later.
3. **Document the format** alongside whatever INFRA-011 settles for ticket metadata — the two are the same family: tooling parsing an undocumented body format.

## Acceptance criteria

- A cycle in the dependency graph is reported as a cycle, naming its members, and never presented as an ordinary block.
- A `Depends on:` line containing prose produces a warning that names the line.
- A line listing only real dependencies parses exactly as before — no behaviour change for well-formed tickets.
- The accepted format is documented in one place.

## Notes

Found while checking why FEAT-059 was not actionable after DEC-020 was filed. Fixed for the tickets involved by moving prose mentions to their own lines, which is a convention that only works because it is now known — the point of this ticket is that it should not require knowing.

## Completion notes

**Cycles (the substantive fix).** `Soldev_ticket.find_dependency_cycle_from ~deps_of start` walks the dependency graph and returns the cycle it closes, trimmed to the cycle itself — so a cycle reached from outside does not report the path taken to reach it. `find_dependency_cycle` runs the same walk against the tickets on disk, and `cycle_blocks` keeps it from firing when a member is already done (a satisfied chain is ordinary waiting, not a deadlock).

Wired into both surfaces: `readiness_label` shows `blocked: dependency cycle A -> B -> A`, and `soldev pipeline check` prints the cycle with a line saying what to look for, then `status: blocked-by-dependency-cycle` instead of `blocked-by-dependency`. Five unit tests, using an injected `deps_of` so they test the walk rather than the repo's current contents: self-cycle, mutual cycle, a cycle reached from outside, a plain chain, and a shared dependency (a diamond, which is not a cycle).

**Deviation on the second criterion, deliberately.** The ticket asked for a warning whenever a `Depends on:` line contains prose. Not implemented as a blanket warning: this repo's tickets legitimately annotate that line (`FEAT-034 (done), FEAT-035 (done).`, `None. (BUG-008's fix already unblocked this.)`), and the parser tolerates it on purpose — a warning would fire on correct tickets, which is how warnings become noise nobody reads. Instead the rule is documented where ticket authoring is described (`.claude/CLAUDE.md`: *every ticket id on that line becomes a dependency*), and the consequence — a cycle — is now loud and named, which is the outcome that actually mattered. If a warning is still wanted, it should be narrowed to a *second field on the line* (an id appearing after a `:` like `Related:`/`Implemented by:`), which is the observed failure shape.
