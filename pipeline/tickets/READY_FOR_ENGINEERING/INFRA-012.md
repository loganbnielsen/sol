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
