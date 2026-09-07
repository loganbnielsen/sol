---
description: "Persona-based adversarial review for a demo or scaffold-facing example: a demo agent (does it actually run end-to-end and show off the platform) and a client agent (is the code an app author has to write appropriately small, or does it hide boilerplate that belongs in a library helper). Iterate fix-and-reconfirm with both personas, then a fresh final reviewer, before treating the demo as done. Use for examples/local-demo, tutorial code samples, or any showcase/onboarding artifact — not for internal framework code with no app-author audience."
---

# /demo-review — does the demo work, and is the abstraction right?

A demo (`examples/local-demo`, a tutorial snippet, a scaffold's generated
`bin/main.ml`) has two audiences ordinary code review doesn't check for:
someone running it to see the platform work, and someone reading it as a
model for their own app code. Correctness review alone misses both. This
skill runs two persona reviewers against the demo, iterating like `/pr`'s
adversarial loop, until both are satisfied and a fresh reviewer confirms.

Do this from a worktree/branch already set up for the ticket (see `/work`
or `/pr` for that setup) — this skill only covers the review loop itself.

## Workflow

1. **Run it for real first.** Before any agent reviews anything, actually
   execute the demo/example end-to-end yourself with whatever local infra
   it needs (see the project's `e2e` skill or its own run instructions).
   Capture the real transcript — stdout, which assertions passed/failed,
   what infra was unavailable. Persona reviewers get this transcript, not
   just the diff — a demo that reads well but doesn't run is not done.
   If something fails for a reason outside this ticket's scope (a
   pre-existing infra bug, a flaky dependency), say so plainly and keep
   the real failure visible — do not quietly loosen an assertion or
   delete a check to make the run look clean.
2. **Demo agent** — launch a fresh subagent (`general-purpose`, not
   `fork`) with: the ticket/task, the diff, and the real run transcript
   from step 1. Ask it to play a developer *demoing this platform to
   someone else* — running it live, narrating what it proves. Give it the
   criteria below under "Demo agent criteria." Ask for concrete findings
   only, most severe first.
3. **Client agent** — launch a second fresh subagent, independent of the
   demo agent (don't let it see the demo agent's findings yet — you want
   an unprimed read). Give it the same diff plus the *user-facing* files
   only (the app-author-visible code: `bin/main.ml`-shaped entrypoints,
   handler bodies, scaffold templates — not the framework internals
   underneath). Ask it to play an app engineer new to this platform,
   evaluating whether it would want to write code that looks like this.
   Give it the criteria below under "Client agent criteria."
4. **Triage.** Merge both agents' findings. For each: is this actually
   this ticket's problem, or does it belong in a different ticket (e.g.
   a pre-existing infra bug uncovered but not caused by this diff)? File
   the latter as its own ticket rather than scope-creeping this one, but
   don't silently drop it either — mention it in the handoff.
5. **Fix and reconfirm.** Apply the actionable fixes. Re-run the demo for
   real again if the fix could plausibly change runtime behavior — don't
   trust a code read alone once a fix touches the execution path. Send
   each persona agent (same agent, follow-up message) the fix summary and
   ask whether it resolves their findings. Iterate until both have no
   actionable feedback.
6. **Fresh final pass.** Start one brand-new agent with no prior
   conclusions (fresh `Agent` call, not a continuation) and give it the
   final diff plus final transcript. Ask it to independently play *both*
   personas and report whether it's satisfied. Iterate if it finds
   something new; this is the exit condition — stop once a fresh agent
   approves.
7. Hand off per the ticket's normal path (`/pr`, `soldev pipeline submit`,
   etc.) — this skill only gates "is the demo actually good," not the
   ticket state machine itself.

## Demo agent criteria

Playing someone running the demo live for an audience:　

1. Does it actually complete without manual intervention (right env vars
   documented, right setup scripts named, no undocumented prerequisite)?
2. Does every capability the demo claims to show (in its header comment,
   README, or the ticket) actually get exercised and confirmed — not just
   attempted? A backend that's wired but whose assertion is silently
   skipped is not "shown off."
3. Would watching this run make someone *understand* the underlying
   capability, or does the interesting part happen off-screen (e.g. a
   trace that's created but never looked up, a metric registered but
   never rendered)?
4. Is the narration/output honest about what's real vs. simulated, and
   about anything that's currently flaky or disabled (link the ticket
   rather than pretend it's fine)?
5. Failure-mode check: if a dependency is down, does the demo fail with a
   clear, actionable message, or hang/crash confusingly?

## Client agent criteria

Playing an app engineer deciding whether they want to write code shaped
like this in their own service:

1. Line-count gut check: does the amount of setup code needed to get logs
   + metrics + traces working feel proportionate, or is there repeated
   boilerplate that every app author would have to retype? If yes, name
   the exact lines and propose the library-level helper that should
   absorb them instead (a new function, not a new module, unless the
   surface genuinely needs one — see this repo's own no-speculative-
   abstraction guidance).
2. Leaky abstraction check: does app-facing code ever have to reach past
   the intended facade into a lower-level module to do something ordinary
   (not an intentionally-exposed escape hatch, an accidental gap)? If the
   facade's own `.mli` documents something as a deliberate bridge for
   framework wiring, that's not a finding — a *new*, undocumented reach-
   through is.
3. Consistency check: do the different primitives (`-svc`/`-worker`/`-fn`,
   or whatever this project's equivalents are) expose the same shape for
   the same concept, or does each reinvent its own variant with no reason
   for the difference?
4. Naming/discoverability: would this app engineer find the right
   function via autocomplete/module signature browsing, or does the
   right way to do something require already knowing an internal
   convention that isn't documented anywhere they'd naturally look?
5. Scope check the other direction too: don't recommend an abstraction
   for something that only happens once, or that's inherently
   framework-internal wiring an app author never touches — a single
   `Sol_obs.obs_eio obs` bridge call to satisfy a lower-level primitive's
   signature is not boilerplate, it's an intentional seam.

## Output

Each agent's findings: concrete, file/line-referenced, ranked by severity,
same bar as `/pr`'s adversarial review — no speculative redesigns, no
non-actionable style preference. The final handoff summarizes: what the
real run showed, what each persona found, what was fixed vs. filed as a
separate ticket, and confirms the fresh final pass approved.
