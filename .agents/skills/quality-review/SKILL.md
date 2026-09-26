---
name: quality-review
description: "Multi-round adversarial subagent review of a diff for architecture/quality standards, not just correctness: layer boundaries, dependency direction, module placement, accidental public API, OCaml type-safety idioms (TYPE_AUDIT.md), reuse/duplication, and test adequacy. Spawns fresh general-purpose reviewers in a fix -> confirm -> fresh-reviewer loop, same mechanics as /pr's adversarial loop, until a completely fresh reviewer finds nothing actionable. Use after finishing an implementation and its own tests, before opening or updating a PR, or whenever asked to run 'our audits' / a quality review against a diff."
---

# /quality-review — loop fresh reviewers on a diff until one comes back clean

`/pr`'s adversarial loop is correctness-first: runtime bugs, contract
boundaries, security. This skill runs the *same loop mechanics* but with
quality/architecture criteria — the kind of thing `code-layer-audit` and
`style-audit` check for a whole repo, scoped instead to one diff. Use it
standalone after `/pr` or a manual implementation pass, once the code
builds and its own tests are green — this skill assumes correctness work is
already done and is checking something different: does this fit the
codebase's standards, or did it just get the feature working.

Not a replacement for `/self-review` (a checklist you run on yourself) or
`/code-review` (a single-pass diff review). This is specifically the
multi-round, fresh-eyes-until-clean loop, generalized to run for quality
the way `/pr` already runs it for correctness.

## Workflow

1. **Confirm the diff is otherwise done.** Build clean, project's own test
   suite green, any project-specific formatter clean (e.g. `dune fmt`).
   Don't start the loop on code that's still failing its own tests —
   reviewers should be judging fit and quality, not doing your correctness
   pass for you.
2. **Pick the diff scope.** Usually `git diff main..HEAD` (or
   `main...HEAD`) in the branch/worktree the work happened in. If the user
   named a narrower range, use that instead — say so in the first
   reviewer's prompt so it doesn't wander into unrelated history.
3. **Round 1 — first reviewer.** Launch a fresh subagent
   (`subagent_type: "general-purpose"` — never `"fork"`, which would
   inherit your own conclusions instead of looking fresh). Give it:
   - The worktree path and branch name, and the exact diff command to run
     itself (don't paste a large diff inline — let it read files in full,
     not just hunks, when a hunk's context matters).
   - Enough task context to judge fit: the ticket or design doc driving the
     work, any explicit constraints it established (an invariant, a red
     line, a decision record) that the diff must uphold.
   - This repo's own quality-relevant docs to hold the diff to (e.g.
     `internal/pipeline/audits/TYPE_AUDIT.md` for OCaml type discipline; the project's
     pre-alpha/no-backwards-compat policy so a reviewer doesn't waste a
     finding on "this changes a public signature").
   - The criteria list below, in priority order.
   - Explicit non-findings: don't flag backwards compatibility in a
     pre-alpha codebase, and don't flag functionality the driving ticket
     itself explicitly defers to a later ticket.
   - A request for concrete, actionable findings only, ordered by
     severity, each with a file:line reference and a one-line fix
     suggestion — and an explicit instruction that "nothing actionable" is
     a valid, useful answer, not a failure to find something.
4. **Fix, verify, commit.** Apply every actionable finding. Rerun the
   build and full test suite (not just the touched module) before
   committing — a "quality" fix can still break something. Commit with a
   message that names which review round the fix came from and why, the
   same way a correctness fix would.
5. **Confirm with the same reviewer.** Send that same agent (via
   `SendMessage`, not a new `Agent` call) a summary of exactly what
   changed and why, and ask it to re-check the current diff and say
   whether its finding(s) are resolved and whether the fix introduces
   anything new. Iterate — fix, re-ask — until that agent has nothing
   actionable left.
6. **Fresh reviewer, next round.** Launch a brand-new `Agent` call (not a
   continuation) with the same kind of prompt as round 1, updated for the
   current diff. Tell it plainly that prior rounds happened and roughly
   what they found and fixed, so it doesn't waste time rediscovering
   settled ground — but tell it explicitly to review the *current* diff
   fresh, on its own merits, and that finding something new, finding the
   same class of issue elsewhere, or finding nothing at all are all valid
   outcomes. Don't let the "prior rounds found less each time" pattern
   pressure it toward manufacturing a finding just to have something to
   report.
7. **Repeat step 4–6** for each new finding, incrementing the round.
8. **Stop condition:** a fresh reviewer (one that has never seen the code
   before, no continuation) reviews the current diff and reports nothing
   actionable. That is the exit condition — not a fixed round count.
   Convergence usually shows up as a visibly decreasing finding count
   round over round; don't stop early just because a round found "only
   one minor thing" — one actionable finding is still a finding, and the
   next fresh round might find another.
9. **Report the loop, not just the result.** When you hand this back,
   summarize round-by-round: what each round found, what was fixed, and
   confirmation that the final round was clean. This is what lets the
   user (or another reviewer) trust the loop actually ran rather than
   being told "looks good" once.

## Criteria (priority order — give this list to every reviewer)

1. **Runtime correctness at contract boundaries** — even though this
   skill is quality-focused, a reviewer that spots a real bug should
   still report it first. Malformed input, error-path correctness,
   data-safety.
2. **Adherence to the diff's own stated invariants** — if the driving
   ticket/design established a boundary (a function that must stay pure,
   an enforcement order, a field deliberately excluded from an identity
   hash), does the diff actually hold it? Does anything that's supposed
   to read only recorded/pure data quietly read ambient state, or vice
   versa (does something that's supposed to read live state suspiciously
   avoid it)?
3. **Architecture / layer boundaries** — is each piece of logic in the
   right module? Sane dependency direction? Any accidental public API
   surface (an internal helper, parser, or validator exported without a
   real external caller)? **Duplicated logic that already exists
   elsewhere in the codebase** — a reviewer should grep for an existing
   helper before assuming something is new; this is one of the highest-
   yield checks in practice.
4. **Type safety / idiom fit** (per this project's own style-audit
   criteria — boolean traps, stringly-typed values that should be
   variants, unjustified sentinel values instead of `option`, positional
   argument debt, nested Option/Result pyramids) — but a sentinel or
   simplification that's explicitly documented and provably unreachable
   in this codebase's domain is a design choice, not a finding; say so
   rather than flagging it reflexively.
5. **Test adequacy** — does every new production code path have a test
   that would actually catch a regression in it? Look specifically for
   wire/serialization round-trips (a field added to a type but never
   asserted through its own encode/decode path is a common miss) and
   pure-but-load-bearing logic that got bundled into "untestable, it
   calls out to \[network/cluster/filesystem\]" when only part of it
   actually does.
6. **Docs accuracy** — do updated docs match what's actually implemented,
   including what's explicitly deferred?

Non-blocking style preferences, broad speculative redesigns, or
functionality the driving ticket already defers are not findings unless
they expose a concrete risk in this diff.

## Notes from running this the first time (FEAT-066, 2026-09-14)

- Four rounds is a reasonable expectation for a diff of a few hundred to
  ~2000 lines touching 20–25 files: round 1 found 2 issues, round 2 found
  1, round 3 found 1 (plus one explicitly-non-blocking nit the reviewer
  itself flagged as not worth a standalone fix — trust that judgment
  rather than fixing everything a reviewer mentions), round 4 found
  nothing and called convergence explicitly.
- The single highest-yield finding type across rounds was **duplicated
  logic** (a helper reimplemented instead of reused) and **untested wire
  paths** (a new field that round-trips through JSON/serialization in
  production but was only ever asserted against in-memory in tests).
  Prioritize telling reviewers to check for both explicitly.
- A reviewer that already confirmed a fix in the same round can also
  independently re-verify a *different* round's fix in passing — cheap
  extra confidence, not required, but worth letting happen naturally
  rather than constraining each reviewer to only its own finding.
