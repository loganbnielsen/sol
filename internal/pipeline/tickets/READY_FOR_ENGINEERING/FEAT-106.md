---
id: FEAT-106
type: feature
severity: high
title: Make the first `sol deploy` guide installation inline instead of requiring a separate bootstrap ritual
source: DEC-057 and docs/DEVELOPER_EXPERIENCE.md §4-5 (2026-09-29)
---

**Depends on:** INFRA-096.

**Related:** `DEC-057` (the contract), `DEC-043` (resolved; named the failure this
removes), `FEAT-107` (the DNS hand-off this flow surfaces), `DEC-016` (target
selection is explicit; no `--env`), `DEC-052` (readiness is observed), `FEAT-090`
(target status), `BUG-094` (preserve state-list failures when resolving an
existing cluster).

## What this is

`DEC-057` §2 requires that a user reaching production for the first time does not
have to learn or invoke a separate bootstrap command. `sol deploy <target>` must
detect an uninitialised installation and guide the user through it in place, then
continue into the deploy.

Today the knowledge lives in operator runbooks and a qualification inventory:
`sol cloud apply` fails when the durable prerequisites are absent, and a user who
does not already know the separate bootstrap root cannot get started (`DEC-043`).

## The experience this must produce

The shape is in `docs/DEVELOPER_EXPERIENCE.md` §5; the properties that matter more
than the wording:

1. **Detection is honest.** `sol deploy` observes whether the installation exists
   and reports what it found — account, region, and the missing prerequisites —
   rather than asserting a state it did not check. An unobservable answer fails
   closed (`DEC-052`).
2. **Automated work and human actions are visually distinct.** The run names the
   one or few external actions (today, DNS delegation) separately from the work
   Sol performs, and does not proceed past a blocker it cannot resolve.
3. **Expensive work happens after cheap, knowable prerequisites.** Validate DNS/TLS
   prerequisites before provisioning when they are knowable, so a user is not made
   to wait through a costly provisioning run for a blocker that could be named
   immediately.
4. **The next run is boring.** After installation, `sol deploy <target>` performs
   no one-time setup and reports the same concise progress as any later deploy.
5. **Runs are resumable.** An interrupted first run re-enters at the stage that
   owns the unmet prerequisite, not from the beginning and not by repeating
   already-installed work (INFRA-096's idempotence).
6. **The stages stay available for diagnosis without becoming required knowledge.**
   A user who wants detail can see the stage a run is in and why it stopped; the
   happy path does not make them address stages explicitly.

## Remediation

- Add the detection and guided path to `sol deploy`, distinct from — but built on
  — the stage INFRA-096 provides. No second implementation of the lifecycle: the
  same stage functions, a different presentation.
- Represent first-run state explicitly (installation absent / partially present /
  present) and drive the prompt from observed facts.
- Make "one action required" a first-class output for the DNS hand-off (FEAT-107),
  including the exact records and a wait/verify step.
- Fail with an actionable message when a prerequisite cannot be satisfied
  automatically, naming the external system and the record or value the user must
  supply.
- Keep `--json`/non-interactive behaviour honest: a CI run must be able to detect
  an uninitialised installation and fail with the same explanation, never hang on
  an interactive prompt, and never silently skip installation.

## Non-goals

- Not a separate `sol init` command as the required path; an explicit
  administrative workflow may exist, but it must not be necessary.
- Not DNS implementation — the hand-off and verification are FEAT-107.
- Not uninstall (FEAT-108).
- Not changing target addressing. The command remains
  `sol deploy <env>/<driver>/<region>`; there is no `--env` (`DEC-016`).
- Not a hosted control plane.

## Acceptance criteria

- On an account with no installation, `sol deploy <target>` detects that, explains
  it, and offers to set up; accepting it reaches a deployed application without the
  user invoking any other command.
- On an account with an installation, `sol deploy <target>` performs no one-time
  setup and no prompt.
- The output distinguishes automated work from external actions, and names the
  exact external action required.
- An interrupted first run resumes at the right stage; a re-run does not repeat
  completed installation work.
- A non-interactive/CI invocation detects an uninitialised installation and fails
  with an actionable explanation rather than prompting or skipping.
- The expensive-provisioning-after-cheap-preflight ordering is observable: a
  knowable DNS/TLS blocker is reported before provisioning begins.

**Demo/example coverage:** the first-run flow is the product's most user-visible
surface, so a runnable example or tutorial section must demonstrate it end to end
(`examples/pluto` and/or `docs/guides/TUTORIAL.md`), and the installation guide
(DOCS-026) must document the same flow.

**TypeScript parity:** No language-parity impact — onboarding is app-language
neutral and no application-facing contract changes.
